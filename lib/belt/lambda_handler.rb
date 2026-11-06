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
        next unless File.directory?(subdir)

        Belt.controller_paths << subdir

        # Auto-require application_controller.rb first (like application_record for models)
        # so other controllers can inherit from it without explicit require_relative
        app_controller = File.join(subdir, 'application_controller.rb')
        require app_controller if File.exist?(app_controller)
      end

      # Auto-load all models (application_record first, then the rest)
      models_dir = File.join(File.dirname(caller_file), 'models')
      return unless File.directory?(models_dir)

      all_models = Dir[File.join(models_dir, '**', '*.rb')]
      app_record = all_models.find { |f| File.basename(f) == 'application_record.rb' }
      rest = all_models - [app_record].compact

      require app_record if app_record
      rest.each { |f| require f }
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
        process_event(event)
      end
    rescue StandardError => e
      error_path = websocket_event?(event) ? event&.dig('requestContext', 'routeKey') : event&.dig('path')
      Belt::Helpers::ErrorLogging.log_error(@logger, 'Unhandled Lambda error', e,
                                            { phase: 'lambda_handler', path: error_path })

      body = { error: 'Internal server error' }
      if verbose_errors_enabled?
        body[:message] = e.message
        body[:type] = e.class.name
        body[:backtrace] = Belt::Helpers::ErrorLogging.filter_backtrace(e.backtrace || [])
      end

      { statusCode: 500, headers: cors_headers, body: JSON.generate(body) }
    end

    private

    def process_event(event)
      invocation = invocation_details(event)
      logger.info('Lambda invoked', **invocation)

      if !websocket_event?(event) && event['httpMethod'] == 'OPTIONS'
        return { statusCode: 200, headers: cors_headers(event), body: '{}' }
      end

      body = parse_request_body(event)
      return body if body.is_a?(Hash) && body[:statusCode]

      path = websocket_event?(event) ? event.dig('requestContext', 'routeKey') : event['path']
      result = execute(path: path, body: body, event: event)
      logger.info('Request completed', status_code: result[:statusCode], **invocation)
      result
    rescue StandardError => e
      handle_error_and_respond(e, 'Unhandled error during request processing', invocation || {})
    end

    def websocket_event?(event)
      event && !event.dig('requestContext', 'connectionId').to_s.empty?
    end

    def invocation_details(event)
      details = { source_ip: event.dig('requestContext', 'identity', 'sourceIp') }
      if websocket_event?(event)
        details.merge(
          route_key: event.dig('requestContext', 'routeKey'),
          connection_id: event.dig('requestContext', 'connectionId')
        )
      else
        details.merge(http_method: event['httpMethod'], path: event['path'])
      end
    end

    def parse_request_body(event)
      raw_body = event['body'] || '{}'

      if raw_body.bytesize > Belt::Helpers::Response::MAX_REQUEST_BODY_SIZE
        return error_response('Request body too large', 413)
      end

      JSON.parse(raw_body)
    rescue JSON::ParserError
      error_response('Invalid JSON in request body', 400)
    end

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
