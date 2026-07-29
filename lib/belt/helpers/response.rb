# frozen_string_literal: true

require_relative 'error_logging'
require_relative 'cors_origin'
require_relative '../http_status'

module Belt
  module Helpers
    module Response
      def cors_headers(event = nil)
        event = @event if event.nil? && instance_variable_defined?(:@event)
        origin = CorsOrigin.resolve_origin(CorsOrigin.origin_from_event(event))
        headers = {
          'Access-Control-Allow-Headers' => 'Content-Type,Accept,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token',
          'Access-Control-Allow-Methods' => 'GET,POST,PUT,DELETE,PATCH,OPTIONS',
          'Access-Control-Max-Age' => '300',
          'Content-Type' => 'application/json'
        }
        headers['Access-Control-Allow-Origin'] = origin if origin
        headers
      end

      # JSON success. Status accepts Integer or Symbol (:created, :ok, …).
      def success_response(body, status_code = 200)
        { statusCode: resolve_status(status_code), headers: cors_headers, body: JSON.generate(body) }
      end

      # JSON error. Status accepts Integer or Symbol (:unprocessable_entity, :not_found, …).
      def error_response(message, status_code = 400, error_details = nil)
        body = { error: message }
        if error_details
          body[:details] = error_details.is_a?(Hash) ? error_details : { message: error_details.to_s }
        end
        { statusCode: resolve_status(status_code), headers: cors_headers, body: JSON.generate(body) }
      end

      def html_response(html, status_code = 200)
        event = @event if instance_variable_defined?(:@event)
        origin = CorsOrigin.resolve_origin(CorsOrigin.origin_from_event(event))
        headers = { 'Content-Type' => 'text/html; charset=utf-8' }
        headers['Access-Control-Allow-Origin'] = origin if origin
        { statusCode: resolve_status(status_code), headers: headers, body: html }
      end

      # Empty-body response (Rails-style). Useful for destroy / create-without-body.
      #
      #   head :created      # 201, empty body
      #   head :no_content   # 204
      #   head 201
      #
      def head(status = :no_content)
        { statusCode: resolve_status(status), headers: cors_headers, body: '' }
      end

      # Set the status used by implicit assigns / HTML render (when you don't
      # call success_response / render yourself).
      #
      #   def create
      #     @post = Post.create!(...)
      #     response_status :created
      #   end
      #   # → 201 + { post: {...} }
      #
      def response_status(status)
        @__response_status = resolve_status(status)
      end

      def handle_error_and_respond(error, message, context = {}, status_code = 500)
        log_error(message, error, context)
        if verbose_errors_enabled?
          error_details = {
            type: error.class.name, message: error.message,
            backtrace: ErrorLogging.filter_backtrace(error.backtrace || []),
            environment: ENV.fetch('ENVIRONMENT', nil)
          }
          error_details[:context] = context unless context.empty?
          error_response(message, status_code, error_details)
        else
          error_response(message, status_code)
        end
      end

      private

      def resolve_status(status)
        Belt::HttpStatus.resolve(status)
      end

      def verbose_errors_enabled?
        env = ENV['ENVIRONMENT']&.downcase || ''
        env.start_with?('dev') || env == 'local' || env == 'test'
      end

      def log_error(message, error, context = {})
        logger_instance = defined?(LOGGER) && LOGGER.respond_to?(:instance) ? LOGGER.instance : @logger
        ErrorLogging.log_error(logger_instance, message, error, context)
      end
    end
  end
end
