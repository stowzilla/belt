# frozen_string_literal: true

module Belt
  module Helpers
    module CorsOrigin
      def self.resolve_origin(request_origin)
        allowed = allowed_origins
        return nil if allowed.empty?
        return request_origin if request_origin && allowed.include?(request_origin)

        allowed.first
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
