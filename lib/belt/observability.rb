# frozen_string_literal: true

module Belt
  # Global facades for Lambda Loadout logger and metrics.
  # Set by Belt::LambdaHandler at the start of each request.
  # Provides clean access to observability from anywhere in the codebase.
  module Observability
    # Logger facade — delegates to a LambdaLoadout::Logger instance
    module Logger
      class << self
        attr_accessor :instance

        def info(message, **context)
          instance&.info(message, **context)
        end

        def error(message, exception = nil, **context)
          if exception
            instance&.error(message, exception, **context)
          else
            instance&.error(message, **context)
          end
        end

        def warn(message, exception = nil, **context)
          if exception
            instance&.warn(message, exception, **context)
          else
            instance&.warn(message, **context)
          end
        end

        def debug(message, **context)
          instance&.debug(message, **context)
        end
      end
    end

    # Metrics facade — delegates to a LambdaLoadout::Metrics instance
    module Metrics
      class << self
        attr_accessor :instance

        def add_metric(name:, unit:, value:)
          instance&.add_metric(name: name, unit: unit, value: value)
        end

        def add_dimension(name:, value:)
          instance&.add_dimension(name: name, value: value)
        end

        def track_event(event_name, **dimensions)
          instance&.add_metric(name: event_name, unit: 'Count', value: 1)
          dimensions.each { |k, v| instance&.add_dimension(name: k.to_s, value: v.to_s) }
        end

        def track_value(metric_name, value, unit: 'None', **dimensions)
          instance&.add_metric(name: metric_name, unit: unit, value: value)
          dimensions.each { |k, v| instance&.add_dimension(name: k.to_s, value: v.to_s) }
        end
      end
    end
  end
end
