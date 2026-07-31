# frozen_string_literal: true

module Belt
  module Helpers
    module CorsOrigin
      # Maximum length for an Origin header to prevent ReDoS or memory abuse.
      MAX_ORIGIN_LENGTH = 253

      def self.resolve_origin(request_origin)
        allowed = allowed_origins
        return nil if allowed.empty?

        if request_origin && valid_origin?(request_origin) && matches_allowed?(request_origin, allowed)
          return request_origin
        end

        # Don't return a wildcard pattern as a literal origin — use '*' instead
        first = allowed.first
        first.include?('*') ? '*' : first
      end

      def self.matches_allowed?(origin, allowed)
        return false unless origin

        allowed.any? do |pattern|
          if pattern.include?('*')
            regex = Regexp.new("\\A#{Regexp.escape(pattern).gsub('\*', '[a-z0-9\\-]+')}\\z")
            regex.match?(origin)
          else
            pattern == origin
          end
        end
      end

      # Validate that the origin looks like a legitimate URL scheme+host.
      # Rejects origins with path components, whitespace, or unexpected characters.
      def self.valid_origin?(origin)
        return false if origin.nil? || origin.empty?
        return false if origin.length > MAX_ORIGIN_LENGTH
        return false unless origin.match?(%r{\A https?://[a-z0-9\-.:]+\z}ix)

        # Reject origins with user-info, paths, queries, or fragments
        !origin.include?('@') && !origin.include?('?') && !origin.include?('#')
      end

      def self.origin_from_event(event)
        return nil unless event.is_a?(Hash)

        headers = event['headers']
        return nil unless headers.is_a?(Hash)

        headers['Origin'] || headers['origin']
      end

      def self.allowed_origins
        @allowed_origins ||= build_allowed_origins
      end

      def self.reset!
        @allowed_origins = nil
      end

      private_class_method def self.build_allowed_origins
        explicit = ENV.fetch('CORS_ALLOWED_ORIGINS', nil)
        return explicit.split(',').map(&:strip).reject(&:empty?) if explicit && !explicit.empty?

        origins = []
        domains = %w[CUSTOMER_APP_DOMAIN OPS_APP_DOMAIN BLOG_APP_DOMAIN]
        domains.each do |var|
          domain = ENV.fetch(var, nil)
          next unless domain && !domain.empty?

          origins << "https://#{domain}"
          origins << "https://www.#{domain}" if domain.count('.') == 1
        end

        env = ENV.fetch('ENVIRONMENT', nil)
        unless %w[prod production staging].include?(env)
          origins << 'http://localhost:3000'
          origins << 'http://localhost:3001'
        end

        origins
      end
    end
  end
end
