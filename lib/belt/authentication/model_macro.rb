# frozen_string_literal: true

require 'activeitem'

module Belt
  module Authentication
    # The declaration, Devise-style. Extended onto ActiveItem::Base so it reads as part
    # of the model DSL rather than as a mixin the app has to know the path to:
    #
    #   class User < ApplicationRecord
    #     cognito_authenticatable
    #   end
    module ModelMacro
      # @param roles [Array<String>] allowed values for `role`. Defaults to
      #   member/admin; extend it if the platform has more than staff and everyone else.
      # @param default_role [String] role given to a newly provisioned user.
      # @param email_index [String, false] GSI name for email lookups, or false if the
      #   app doesn't need to resolve people by email.
      def cognito_authenticatable(roles: nil, default_role: nil, email_index: nil)
        include Belt::Authentication::CognitoAuthenticatable

        self.cognito_roles = roles.map(&:to_s) if roles
        self.cognito_default_role = default_role.to_s if default_role
        self.cognito_email_index = email_index unless email_index.nil?

        validate_cognito_default_role!
        self
      end

      # Whether this model has declared cognito_authenticatable.
      def cognito_authenticatable?
        include?(Belt::Authentication::CognitoAuthenticatable)
      end

      private

      def validate_cognito_default_role!
        return if cognito_roles.include?(cognito_default_role)

        raise ArgumentError,
              "default_role #{cognito_default_role.inspect} is not in roles #{cognito_roles.inspect}"
      end
    end
  end
end

ActiveItem::Base.extend(Belt::Authentication::ModelMacro)
