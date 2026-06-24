# frozen_string_literal: true

require 'json'
require 'lambda_loadout'
require_relative 'observability'
require_relative 'helpers/response'

module Belt
  # Lambda handler module — include in your Lambda entry point to get automatic
  # observability setup, CORS preflight handling, JSON body parsing, and error wrapping.
  #
  # Usage:
  #   require "belt"
  #
  #   include Belt::LambdaHandler
  #
  #   def execute(path:, body:, event:)
  #     ROUTER.route(event: event, body: body)
  #   end
  #
  module LambdaHandler
    include Belt::Helpers::Response

    attr_accessor :logger, :metrics

    def self.included(base)
      base.instance_variable_set(:@belt_lambda_handler_included, true)

      # Skip auto-registration in test environments to avoid stale paths
      return if ENV['BELT_ENV'] == 'test' || ENV['RACK_ENV'] == 'test' || defined?(RSpec)

      # Auto-register controllers directory relative to the including file's location
      caller_file = caller_locations(1, 1)&.first&.path
      return unless caller_file

      controllers_dir = File.join(File.dirname(caller_file), 'controllers')
      return unless File.directory?(controllers_dir)

      Belt.controller_paths << controllers_dir
      Dir.children(controllers_dir).each do |child|
        subdir = File.join(controllers_dir, child)
        Belt.controller_paths << subdir if File.directory?(subdir)
      end
    end

    # API Gateway Lambda handler.
    # Handles HTTP requests with automatic CORS, body parsing, observability, and error wrapping.
    # Override `execute` to provide your own routing logic.
    def lambda_handler(event:, context:)
      init_observability(context: context)

      LambdaLoadout.with_logging_and_metrics(
        logger,
        metrics,
        context,
        event: event,
        error_notification_config: {
          sns_topic_arn: ENV.fetch('ERROR_NOTIFICATION_TOPIC_ARN', nil)
        }
      ) do
        logger.info('Lambda invoked',
                    http_method: event['httpMethod'],
                    path: event['path'],
                    source_ip: event.dig('requestContext', 'identity', 'sourceIp'))

        return { statusCode: 200, headers: cors_headers(event), body: '{}' } if event['httpMethod'] == 'OPTIONS'

        begin
          body = JSON.parse(event['body'] || '{}')
        rescue JSON::ParserError
          return error_response('Invalid JSON in request body')
        end

        begin
          result = execute(path: event['path'], body: body, event: event)
          logger.info('Request completed', status_code: result[:statusCode], path: event['path'])
          result
        rescue StandardError => e
          handle_error_and_respond(e, 'Unhandled error during request processing',
                                   { path: event['path'], method: event['httpMethod'] })
        end
      end
    rescue StandardError => e
      Belt::Helpers::ErrorLogging.log_error(@logger, 'Unhandled Lambda error', e,
                                            { phase: 'lambda_handler', path: event&.dig('path') })

      body = { error: 'Internal server error' }
      if verbose_errors_enabled?
        body[:message] = e.message
        body[:type] = e.class.name
        body[:backtrace] = Belt::Helpers::ErrorLogging.filter_backtrace(e.backtrace || [])
      end

      { statusCode: 500, headers: cors_headers, body: JSON.generate(body) }
    end

    private

    def init_observability(context:)
      service_name = ENV['ACTION'] || context.function_name.split('-').last

      @logger = LambdaLoadout::Logger.new(service: service_name)
      @metrics = LambdaLoadout::Metrics.new(
        namespace: ENV['BELT_METRICS_NAMESPACE'] || 'Belt',
        service: service_name
      )

      Belt::Observability::Logger.instance = @logger
      Belt::Observability::Metrics.instance = @metrics
    end
  end
end
