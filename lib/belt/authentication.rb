# frozen_string_literal: true

require_relative 'errors'
require_relative 'configuration'
require_relative 'authentication/configuration'
require_relative 'authentication/claims'
require_relative 'authentication/cognito_authenticatable'
require_relative 'authentication/model_macro'
require_relative 'authentication/controller'
require_relative 'authentication/session_cookie'
module Belt
  # Cognito-backed identity for Belt apps.
  #
  # Cognito owns authentication (passwords, MFA, groups). Belt owns the *record* of the
  # human it authenticated, so the app can answer its own questions about them without
  # re-reading JWT claims everywhere.
  #
  # Declare it on a model, Devise-style:
  #
  #   class User < ApplicationRecord
  #     cognito_authenticatable
  #   end
  #
  # That single line supplies the identity attributes (email, name, role,
  # email_verified, last_seen_on), the EmailIndex GSI, and the class methods that
  # provision a row from a token — see Authentication::CognitoAuthenticatable.
  #
  # Controllers get `current_user`, `authenticate_user!`, `user_signed_in?` and
  # `cognito_admin?` for free (Authentication::Controller is mixed into
  # BeltController::Base), so a request never has to decode a JWT by hand.
  #
  # Rows are provisioned just-in-time on the first authenticated request. There is no
  # signup endpoint to keep in step with Cognito's hosted UI.
  module Authentication
    # Raised when a request carries no usable Cognito identity and one is required.
    # A subclass of Belt::AuthenticationError so BeltController's existing
    # rescue_from mapping (401) applies without any app-level wiring.
    class NotAuthenticated < Belt::AuthenticationError; end
  end
end
