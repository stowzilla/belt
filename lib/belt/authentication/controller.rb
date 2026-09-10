# frozen_string_literal: true

module Belt
  module Authentication
    # Cognito identity for controllers. Mixed into BeltController::Base, so every
    # controller already has it:
    #
    #   class ProfilesController < ApplicationController
    #     before_action :authenticate_user!
    #
    #     def show
    #       @profile = current_user
    #     end
    #   end
    #
    # `current_user` returns a record of the app's user model (see
    # CognitoAuthenticatable), provisioned just-in-time on first sight. Nothing in a
    # controller needs to decode a token, read a claim, or parse a Cognito group.
    #
    # Every ivar here is listed in ImplicitResponse::FRAMEWORK_IVARS, so an identity
    # resolved mid-action never leaks into a JSON response body.
    module Controller
      # The raw `Authorization` header, however the client cased it.
      def authorization_header
        Claims.authorization_header(event)
      end

      # The raw Bearer credential — whatever it is. An app whose API accepts its own
      # token format alongside Cognito reads it here and decides for itself.
      def bearer_token
        Claims.bearer_token(event)
      end

      # The Cognito claims on this request, or nil if there aren't any. Memoized
      # including the nil, so a request decodes at most once.
      def cognito_claims
        return @cognito_claims if defined?(@cognito_claims)

        @cognito_claims = Claims.from_event(event, issuer: belt_authentication_config.issuer)
      end

      def cognito_sub
        cognito_claims && cognito_claims['sub']
      end

      def cognito_email
        cognito_claims && cognito_claims['email']
      end

      # Cognito groups on the current token. Prefer #cognito_admin? or a role on
      # #current_user over reading this directly.
      def cognito_groups
        return @cognito_groups if defined?(@cognito_groups)

        @cognito_groups = Claims.groups(cognito_claims)
      end

      # Does this token grant platform staff access? The *grant* mechanism —
      # `current_user.admin?` mirrors it, which is what the rest of the app should ask,
      # so that a user's staff status is answerable without a token in hand.
      def cognito_admin?
        cognito_groups.intersect?(belt_authentication_config.admin_groups)
      end

      # The user record behind the token on this request, or nil when the request
      # carries no Cognito identity (anonymous, or an app-specific credential such as
      # an API key).
      #
      # Provisioned on first sight and refreshed only on drift — see
      # CognitoAuthenticatable.sync_from_claims!. Memoized including the nil.
      def current_user
        return @current_user if defined?(@current_user)

        @current_user = resolve_cognito_user
      end

      def user_signed_in?
        !current_user.nil?
      end

      # Suppress Cognito resolution for a request authenticated some other way — an
      # app's own API key, a machine token. Default false: always attempt.
      #
      # Usually unnecessary, since a credential that isn't a Cognito ID token yields no
      # claims and therefore no user. It matters when a request could carry both, and
      # the app's answer is "this caller is not a human".
      def skip_cognito_identity?
        false
      end

      # before_action guard. Raises, because Belt discards before_action return values
      # (see BeltController::Base#run_before_actions) — returning a response hash would
      # let the action run anyway. Belt maps the error to 401.
      def authenticate_user!
        raise NotAuthenticated, 'Authentication required' unless user_signed_in?
      end

      private

      def resolve_cognito_user
        return nil if skip_cognito_identity?

        claims = cognito_claims
        return nil if claims.nil?

        model = belt_authentication_config.user_class
        return nil unless model.respond_to?(:sync_from_claims!)

        model.sync_from_claims!(
          sub: claims['sub'],
          email: claims['email'],
          name: claims['name'],
          admin: cognito_admin?,
          email_verified: claims['email_verified']
        )
      end

      def belt_authentication_config
        Belt.configuration.authentication
      end
    end
  end
end
