# frozen_string_literal: true

require 'active_support/concern'

module Belt
  module Authentication
    # Everything a Belt app needs to know about a Cognito-authenticated human,
    # without writing any of it.
    #
    #   class User < ApplicationRecord
    #     cognito_authenticatable
    #   end
    #
    # What that gets you:
    #
    #   * Primary key **is** the Cognito `sub`. Resolving the caller is one GetItem,
    #     and the sub becomes a usable foreign key everywhere else in the schema.
    #   * Attributes: email, name, role, email_verified, last_seen_on.
    #   * An `EmailIndex` GSI, so invitations (addressed to an email before the invitee
    #     has an account) can find their person.
    #   * `.sync_from_claims!` — just-in-time provisioning from a token, write-averse
    #     enough to sit on the authenticated request path.
    #   * `#admin?` — platform staff, mirrored from a Cognito group on every request.
    #
    # Options:
    #
    #   cognito_authenticatable roles: %w[member admin support],  # default member/admin
    #                           default_role: 'member',
    #                           email_index: 'PeopleEmailIndex'   # or false to skip
    #
    # The app's own domain stays the app's: memberships, orgs, plans, per-tenant roles.
    # This concern only owns identity.
    module CognitoAuthenticatable
      extend ActiveSupport::Concern

      # Platform-wide role. `admin` means staff — someone who can see across tenants.
      # Not to be confused with a per-tenant role, which the app models itself.
      ROLES = %w[member admin].freeze
      ADMIN_ROLE = 'admin'
      DEFAULT_ROLE = 'member'
      DEFAULT_EMAIL_INDEX = 'EmailIndex'

      # DynamoDB attribute names for the identity attributes. Snake_case, not
      # ActiveItem's default camelCase, so they read the same in the console, in
      # `dynamodb.tf`, and in a GSI key definition.
      ATTRIBUTE_MAP = {
        'id' => 'id',
        'email' => 'email',
        'name' => 'name',
        'role' => 'role',
        'email_verified' => 'email_verified',
        'last_seen_on' => 'last_seen_on'
      }.freeze

      # Merges the identity schema into whatever the model declares itself, in either
      # order. Prepended to the model's singleton rather than assigned in `included do`
      # because ActiveItem's `indexes` / `dynamo_attribute_map` writers replace instead
      # of merge — an app declaring its own index after the macro would otherwise drop
      # EmailIndex on the floor, silently, until a lookup failed in production.
      #
      # App declarations win on conflict.
      module SchemaDefaults
        def indexes(definitions = nil)
          return super if definitions

          cognito_email_index_definition.merge(super())
        end

        def dynamo_attribute_map(mappings = nil)
          return super if mappings

          ATTRIBUTE_MAP.merge(super())
        end
      end

      included do
        attr_accessor :email,          # Cognito `email` claim, normalized to lowercase.
                      :name,           # Cognito `name` claim, or the email local part.
                      :role,           # Platform role — see ROLES.
                      :email_verified, # Cognito `email_verified`.
                      :last_seen_on    # ISO date, not a timestamp — see .sync_from_claims!

        # Email is deliberately NOT validated. It comes from a verified token rather
        # than a form, and this model is written on the authentication path: a
        # validation failure here would 500 every request instead of rejecting input.
        validates :role, presence: true, inclusion: { in: ->(record) { record.class.cognito_roles } }

        singleton_class.prepend(SchemaDefaults)
      end

      # Platform staff. Mirrored from the Cognito group on every request, so a
      # revocation takes effect on the caller's next call.
      def admin?
        role.to_s == ADMIN_ROLE
      end

      def email_verified?
        Claims.truthy?(email_verified)
      end

      # Hook for whatever the app wants to happen each time an identity is resolved
      # from a token — binding pending invitations, seeding a default workspace, an
      # audit trail. No-op by default; override in the model.
      def after_cognito_sync; end
    end
  end
end

require_relative 'cognito_authenticatable/class_methods'
