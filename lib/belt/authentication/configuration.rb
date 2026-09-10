# frozen_string_literal: true

module Belt
  module Authentication
    # Authentication settings, reachable from the runtime config:
    #
    #   Belt.configure do |config|
    #     config.authentication.user_class  = 'Account'   # default: 'User'
    #     config.authentication.admin_groups = %w[staff]  # default: ['admins']
    #   end
    #
    # Every setting has a working default, so an app that names its model `User` and
    # its Cognito group `admins` configures nothing.
    class Configuration
      # Cognito groups whose members are platform staff. NOT a per-tenant role — that
      # belongs to the app's own domain (a membership, an org role, whatever).
      DEFAULT_ADMIN_GROUPS = %w[admins].freeze

      DEFAULT_USER_CLASS = 'User'

      def initialize
        @user_class = nil
        @admin_groups = nil
        @issuer = nil
      end

      attr_writer :admin_groups, :issuer

      # Accepts a class or a name. Stored as a name and resolved on demand so the
      # setting can be declared before the model file is loaded.
      def user_class=(value)
        @user_class = value.is_a?(Class) ? value.name : value&.to_s
      end

      def user_class_name
        @user_class || DEFAULT_USER_CLASS
      end

      # The model backing #current_user, or nil if the app hasn't defined one.
      # Nil is a legitimate answer: an app can use Belt's Cognito plumbing without
      # persisting a user row at all.
      def user_class
        Object.const_get(user_class_name)
      rescue NameError
        nil
      end

      def admin_groups
        return Array(@admin_groups).map(&:to_s) if @admin_groups

        configured = ENV.fetch('ADMIN_COGNITO_GROUPS', '').to_s.split(',').map(&:strip).reject(&:empty?)
        configured.empty? ? DEFAULT_ADMIN_GROUPS : configured
      end

      # Expected `iss` claim. Derived from the Cognito env vars Belt's Terraform module
      # already exports, so apps don't restate it. Nil disables the issuer check —
      # which is the right behaviour locally and in tests, where there is no pool.
      def issuer
        return @issuer if @issuer

        pool_id = ENV.fetch('COGNITO_USER_POOL_ID', nil)
        return nil if pool_id.to_s.empty?

        region = ENV['COGNITO_REGION'] || ENV['AWS_REGION'] || 'us-east-1'
        "https://cognito-idp.#{region}.amazonaws.com/#{pool_id}"
      end
    end
  end
end
