# frozen_string_literal: true

module Belt
  module Helpers
    module ErrorLogging
      module_function

      def log_error(logger, message, error, context = {})
        filtered_backtrace = filter_backtrace(error.backtrace || [])

        if logger
          logger.error(message,
                       error_class: error.class.name,
                       error_message: error.message,
                       backtrace: filtered_backtrace,
                       backtrace_full: error.backtrace&.first(20),
                       **context)
        else
          require 'json'
          puts JSON.generate({
                               level: 'ERROR',
                               message: message,
                               error_class: error.class.name,
                               error_message: error.message,
                               backtrace: filtered_backtrace,
                               timestamp: Time.now.utc.iso8601,
                               **context
                             })
        end
      end

      def filter_backtrace(backtrace)
        return [] if backtrace.nil? || backtrace.empty?

        app_patterns = [%r{/var/task/}, %r{lambda/}, %r{controllers/}, %r{models/}, %r{lib/}, %r{helpers/}]
        exclude_patterns = [%r{/var/runtime/}, %r{/opt/ruby/}, %r{/gems/}, /rubygems/, /<internal:/]

        app_lines = []
        lib_lines = []

        backtrace.each do |line|
          next if exclude_patterns.any? { |pattern| line.match?(pattern) }

          if app_patterns.any? { |pattern| line.match?(pattern) }
            app_lines << line
          else
            lib_lines << line
          end
        end

        (app_lines.first(10) + lib_lines.first(3)).compact
      end
    end
  end
end
