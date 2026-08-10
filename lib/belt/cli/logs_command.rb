# frozen_string_literal: true

require 'json'
require 'open3'

module Belt
  module CLI
    class LogsCommand
      include AppDetection

      COLORS = {
        red: "\e[0;31m",
        green: "\e[0;32m",
        yellow: "\e[0;33m",
        blue: "\e[0;34m",
        magenta: "\e[0;35m",
        cyan: "\e[0;36m",
        gray: "\e[0;90m",
        bold: "\e[1m",
        dim: "\e[2m",
        reset: "\e[0m"
      }.freeze

      def self.run(args)
        if args.include?('--help') || args.include?('-h')
          puts usage
          exit 0
        end

        new(args).run
      end

      def self.usage
        <<~USAGE
          Usage: belt logs [lambda] [options]

          View Lambda function logs. Without arguments, tails all Lambdas for the current environment.

          Arguments:
            lambda              Lambda function short name (e.g., api, worker). Optional — shows all if omitted.

          Options:
            -e, --env ENV       Environment (default: BELT_ENV or first detected)
            -f, --follow        Follow logs in real-time
            -s, --since PERIOD  Time range (default: 5m). Examples: 5m, 30m, 1h, 2h
            -l, --level LEVEL   Minimum log level: DEBUG, INFO, WARN, ERROR (default: INFO)
            --error             Show only the most recent error and exit
            --raw               Show raw JSON logs without formatting
            --no-color          Disable colorized output
            -h, --help          Show this help

          Examples:
            belt logs                    # Last 5m of all lambdas (current env)
            belt logs api                # Last 5m of api lambda
            belt logs api -f             # Follow api lambda logs
            belt logs -e prod            # Last 5m of all lambdas in prod
            belt logs api -s 30m         # Last 30 minutes
            belt logs --error            # Show most recent error across all lambdas
            belt logs api --error        # Show most recent error for api lambda
        USAGE
      end

      def initialize(args)
        @lambda_name = nil
        @env = nil
        @follow = false
        @since = '5m'
        @level = 'INFO'
        @error_mode = false
        @raw = false
        @color = $stdout.tty?
        parse_args(args)
      end

      def run
        @env ||= detect_environment
        abort 'Error: Cannot determine environment. Pass -e ENV or set BELT_ENV.' unless @env

        @app_name = detect_app_name
        abort 'Error: Cannot determine app name.' unless @app_name

        if @lambda_name
          tail_single(@lambda_name)
        else
          tail_all
        end
      end

      private

      def parse_args(args)
        i = 0
        while i < args.length
          case args[i]
          when '-e', '--env'
            @env = args[i + 1]
            i += 2
          when '-f', '--follow'
            @follow = true
            i += 1
          when '-s', '--since'
            @since = args[i + 1]
            i += 2
          when '-l', '--level'
            @level = args[i + 1]&.upcase
            i += 2
          when '--error'
            @error_mode = true
            i += 1
          when '--raw'
            @raw = true
            i += 1
          when '--no-color'
            @color = false
            i += 1
          else
            @lambda_name = args[i] unless args[i].start_with?('-')
            i += 1
          end
        end
      end

      def detect_environment
        ENV.fetch('BELT_ENV', nil) || detect_environments.first
      end

      def tail_single(lambda_name)
        log_group = log_group_for(lambda_name)

        unless log_group_exists?(log_group)
          abort "#{c(:red)}✗ No log group found: #{log_group}#{c(:reset)}\n  " \
                'The Lambda may not have been deployed yet.'
        end

        if @error_mode
          find_recent_error(log_group, lambda_name)
        elsif @follow
          follow_logs(log_group, lambda_name)
        else
          fetch_historical(log_group, lambda_name)
        end
      end

      def tail_all
        lambdas = discover_lambda_names
        if lambdas.empty?
          abort "#{c(:red)}✗ No Lambda functions found for #{@app_name}-#{@env}#{c(:reset)}\n  " \
                "Deploy with `belt deploy #{@env}` first, or specify a lambda name: `belt logs api`"
        end

        if @error_mode
          find_errors_across(lambdas)
        elsif @follow
          follow_all(lambdas)
        else
          fetch_all_historical(lambdas)
        end
      end

      def discover_lambda_names
        names = lambda_names_from_terraform
        return names if names.any?

        lambda_names_from_log_groups
      end

      def lambda_names_from_terraform
        infra_dir = find_infra_dir
        env_dir = infra_dir ? File.join(infra_dir, @env) : nil
        return [] unless env_dir && Dir.exist?(File.join(env_dir, '.terraform'))

        Dir.chdir(env_dir) do
          output, status = Open3.capture2('terraform', 'output', '-json')
          return [] unless status.success?

          data = begin
            JSON.parse(output)
          rescue JSON::ParserError
            {}
          end

          if data['lambda_functions']
            funcs = data['lambda_functions']['value']
            if funcs.is_a?(Hash)
              return funcs.keys
            elsif funcs.is_a?(Array)
              return funcs.map { |f| f.is_a?(String) ? f.split('-').last : nil }.compact
            end
          end

          data.keys.grep(/_function_name$/).map { |k| data[k]['value']&.split('-')&.last }.compact
        end
      rescue StandardError
        []
      end

      def lambda_names_from_log_groups
        prefix = "/aws/lambda/#{@app_name}-#{@env}-"
        output, status = Open3.capture2(
          'aws', 'logs', 'describe-log-groups',
          '--log-group-name-prefix', prefix,
          '--query', 'logGroups[].logGroupName',
          '--output', 'json'
        )
        return [] unless status.success?

        groups = begin
          JSON.parse(output)
        rescue JSON::ParserError
          []
        end
        groups.map { |g| g.sub(prefix, '') }
      end

      def log_group_for(lambda_name)
        "/aws/lambda/#{@app_name}-#{@env}-#{lambda_name}"
      end

      def log_group_exists?(log_group)
        _, status = Open3.capture2(
          'aws', 'logs', 'describe-log-groups',
          '--log-group-name-prefix', log_group,
          '--query', "logGroups[?logGroupName=='#{log_group}'].logGroupName",
          '--output', 'text'
        )
        status.success?
      end

      def follow_logs(log_group, lambda_name)
        print_header(lambda_name)
        puts "#{c(:yellow)}Following logs (Ctrl+C to stop)...#{c(:reset)}\n\n"

        cmd = ['aws', 'logs', 'tail', log_group, '--follow', '--format', 'short']
        IO.popen(cmd, err: %i[child out]) do |io|
          io.each_line { |line| process_tail_line(line) }
        end
      rescue Interrupt
        puts "\n#{c(:dim)}Stopped.#{c(:reset)}"
      end

      def follow_all(lambdas)
        puts "#{c(:cyan)}═══════════════════════════════════════════════════════════════#{c(:reset)}"
        puts "#{c(:bold)}Lambda Logs: #{c(:magenta)}#{@app_name}-#{@env}#{c(:reset)} (#{lambdas.join(', ')})"
        puts "#{c(:cyan)}═══════════════════════════════════════════════════════════════#{c(:reset)}"
        puts "#{c(:yellow)}Following logs (Ctrl+C to stop)...#{c(:reset)}\n\n"

        threads = lambdas.map do |name|
          log_group = log_group_for(name)
          Thread.new do
            cmd = ['aws', 'logs', 'tail', log_group, '--follow', '--format', 'short']
            IO.popen(cmd, err: %i[child out]) do |io|
              io.each_line { |line| process_tail_line(line, prefix: name) }
            end
          rescue StandardError
            nil
          end
        end

        threads.each(&:join)
      rescue Interrupt
        puts "\n#{c(:dim)}Stopped.#{c(:reset)}"
      end

      def fetch_historical(log_group, lambda_name)
        print_header(lambda_name)
        puts "#{c(:dim)}Fetching last #{@since} of logs...#{c(:reset)}\n\n"

        events = fetch_log_events(log_group)
        if events.empty?
          puts "#{c(:yellow)}No logs found in the last #{@since}#{c(:reset)}"
          return
        end

        puts "#{c(:dim)}Found #{events.length} log events#{c(:reset)}\n\n"
        events.each { |event| process_event(event) }

        puts "\n#{c(:cyan)}═══════════════════════════════════════════════════════════════#{c(:reset)}"
        puts "#{c(:dim)}Tip: Use -f to follow logs in real-time#{c(:reset)}"
      end

      def fetch_all_historical(lambdas)
        puts "#{c(:cyan)}═══════════════════════════════════════════════════════════════#{c(:reset)}"
        puts "#{c(:bold)}Lambda Logs: #{c(:magenta)}#{@app_name}-#{@env}#{c(:reset)} (#{lambdas.join(', ')})"
        puts "#{c(:cyan)}═══════════════════════════════════════════════════════════════#{c(:reset)}"
        puts "#{c(:dim)}Fetching last #{@since} of logs...#{c(:reset)}\n\n"

        all_events = []
        lambdas.each do |name|
          log_group = log_group_for(name)
          events = fetch_log_events(log_group)
          events.each { |e| e['_lambda'] = name }
          all_events.concat(events)
        end

        all_events.sort_by! { |e| e['timestamp'] || 0 }

        if all_events.empty?
          puts "#{c(:yellow)}No logs found in the last #{@since}#{c(:reset)}"
          return
        end

        puts "#{c(:dim)}Found #{all_events.length} log events#{c(:reset)}\n\n"
        all_events.each { |event| process_event(event, prefix: event['_lambda']) }

        puts "\n#{c(:cyan)}═══════════════════════════════════════════════════════════════#{c(:reset)}"
        puts "#{c(:dim)}Tip: Use -f to follow logs in real-time#{c(:reset)}"
      end

      def find_recent_error(log_group, lambda_name)
        events = fetch_log_events(log_group, since: '30m', limit: 500)
        error = find_error_in_events(events)

        if error
          puts "#{c(:bold)}Most recent error in #{c(:magenta)}#{lambda_name}#{c(:reset)}:\n\n"
          format_error_event(error)
        else
          puts "#{c(:green)}✓ No errors found in the last 30 minutes for #{lambda_name}#{c(:reset)}"
        end
      end

      def find_errors_across(lambdas)
        latest_error = nil
        latest_lambda = nil

        lambdas.each do |name|
          log_group = log_group_for(name)
          events = fetch_log_events(log_group, since: '30m', limit: 500)
          error = find_error_in_events(events)
          next unless error

          if latest_error.nil? || (error['timestamp'] || 0) > (latest_error['timestamp'] || 0)
            latest_error = error
            latest_lambda = name
          end
        end

        if latest_error
          puts "#{c(:bold)}Most recent error in #{c(:magenta)}#{latest_lambda}#{c(:reset)}:\n\n"
          format_error_event(latest_error)
        else
          puts "#{c(:green)}✓ No errors found in the last 30 minutes#{c(:reset)}"
        end
      end

      def find_error_in_events(events)
        events.reverse_each do |event|
          msg = event['message'] || ''
          json = parse_json(msg)
          next unless json

          return event if json['errorMessage'] && json['errorType'] && json['stackTrace']
          return event if json['level'] == 'ERROR'
          return event if json['status_code'].to_i >= 500
        end
        nil
      end

      def format_error_event(event)
        msg = event['message'] || ''
        json = parse_json(msg)
        return puts(msg) unless json

        timestamp = format_timestamp(event['timestamp'])

        if json['errorMessage'] && json['errorType']
          format_init_error(json, timestamp)
        else
          format_structured_log(json, timestamp)
        end
      end

      def format_init_error(json, timestamp)
        puts "#{c(:gray)}#{timestamp}#{c(:reset)} #{c(:red)}#{c(:bold)}INIT ERROR#{c(:reset)}"
        puts "  #{c(:dim)}Type:#{c(:reset)}    #{c(:red)}#{json['errorType']}#{c(:reset)}"
        puts "  #{c(:dim)}Message:#{c(:reset)} #{json['errorMessage']}"
        return unless json['stackTrace'].is_a?(Array)

        puts "  #{c(:dim)}Stack:#{c(:reset)}"
        json['stackTrace'].first(15).each do |line|
          if line.match?(%r{(controllers|models|lib|helpers)/})
            puts "    #{c(:yellow)}→#{c(:reset)} #{line}"
          elsif line.include?('/var/task/')
            puts "    #{c(:cyan)}→#{c(:reset)} #{line}"
          else
            puts "    #{c(:gray)}  #{line}#{c(:reset)}"
          end
        end
      end

      def fetch_log_events(log_group, since: @since, limit: 1000)
        duration_ms = parse_since(since)
        start_time = (Time.now.to_i * 1000) - duration_ms

        output, status = Open3.capture2(
          'aws', 'logs', 'filter-log-events',
          '--log-group-name', log_group,
          '--start-time', start_time.to_s,
          '--limit', limit.to_s,
          '--output', 'json'
        )
        return [] unless status.success?

        data = begin
          JSON.parse(output)
        rescue JSON::ParserError
          {}
        end
        data['events'] || []
      end

      def process_tail_line(line, prefix: nil)
        return if line.match?(/\b(START|END|REPORT|INIT_START|INIT_REPORT)\s/)
        return if line.include?('[LambdaLoadout') || line.include?('"_aws":')

        if line.include?('Critical exception from handler')
          prefix_str = prefix ? "#{c(:blue)}[#{prefix}]#{c(:reset)} " : ''
          puts "#{prefix_str}#{c(:red)}#{c(:bold)}CRITICAL EXCEPTION#{c(:reset)}"
          return
        end

        json_part = line.sub(/\A[\dT:.+\-Z ]+\s*/, '').strip
        json = parse_json(json_part)

        if json
          if json['errorMessage'] && json['errorType'] && json['stackTrace']
            format_aws_error(json, prefix: prefix)
          elsif @raw
            puts json_part
          else
            timestamp = extract_time_from_line(line)
            format_structured_log(json, timestamp, prefix: prefix)
          end
        elsif line.strip.length.positive?
          prefix_str = prefix ? "#{c(:blue)}[#{prefix}]#{c(:reset)} " : ''
          puts "#{prefix_str}#{c(:gray)}#{line.strip}#{c(:reset)}"
        end
      end

      def process_event(event, prefix: nil)
        msg = event['message'] || ''

        return if msg.match?(/\A(START|END|REPORT|INIT_START|INIT_REPORT)\s/)
        return if msg.include?('[LambdaLoadout') || msg.include?('"_aws":')

        if msg.include?('Critical exception from handler')
          prefix_str = prefix ? "#{c(:blue)}[#{prefix}]#{c(:reset)} " : ''
          puts "#{prefix_str}#{c(:red)}#{c(:bold)}CRITICAL EXCEPTION#{c(:reset)}"
          return
        end

        json = parse_json(msg)
        timestamp = format_timestamp(event['timestamp'])

        if json
          if json['errorMessage'] && json['errorType'] && json['stackTrace']
            format_aws_error(json, prefix: prefix)
          elsif @raw
            puts JSON.pretty_generate(json)
          else
            format_structured_log(json, timestamp, prefix: prefix)
          end
        elsif msg.strip.length.positive?
          prefix_str = prefix ? "#{c(:blue)}[#{prefix}]#{c(:reset)} " : ''
          puts "#{prefix_str}#{c(:gray)}#{msg.strip}#{c(:reset)}"
        end
      end

      def format_structured_log(json, timestamp, prefix: nil)
        level = json['level']
        message = json['message'] || ''

        return unless should_show_level?(level)

        prefix_str = prefix ? "#{c(:blue)}[#{prefix}]#{c(:reset)} " : ''

        case level
        when 'ERROR'
          format_error_log(json, message, timestamp, prefix_str)
        when 'WARN'
          format_warn_log(json, message, timestamp, prefix_str)
        else
          format_info_log(json, message, timestamp, prefix_str)
        end
      end

      def format_error_log(json, message, timestamp, prefix_str)
        puts "#{prefix_str}#{c(:gray)}#{timestamp}#{c(:reset)} " \
             "#{c(:red)}ERROR#{c(:reset)} #{c(:bold)}#{message}#{c(:reset)}"
        puts "  #{c(:dim)}Action:#{c(:reset)} #{json['action']}" if json['action']
        if json['error_class']
          puts "  #{c(:dim)}Error:#{c(:reset)}  " \
               "#{c(:red)}#{json['error_class']}#{c(:reset)}: #{json['error_message']}"
        end
        puts "  #{c(:dim)}Path:#{c(:reset)}   #{json['path']}" if json['path']
        format_backtrace(json['backtrace'])
      end

      def format_warn_log(json, message, timestamp, prefix_str)
        puts "#{prefix_str}#{c(:gray)}#{timestamp}#{c(:reset)} #{c(:yellow)}WARN#{c(:reset)} #{message}"
        if json['error_class']
          puts "  #{c(:dim)}Error:#{c(:reset)} " \
               "#{c(:red)}#{json['error_class']}#{c(:reset)}: #{json['error_message']}"
        end
        puts "  #{c(:dim)}Path:#{c(:reset)} #{json['path']}" if json['path']
        format_backtrace(json['backtrace'])
      end

      def format_info_log(json, message, timestamp, prefix_str)
        case message
        when 'Lambda invoked'
          path = strip_namespace(json['path'])
          puts "#{prefix_str}#{c(:gray)}#{timestamp}#{c(:reset)} " \
               "#{c(:cyan)}Started#{c(:reset)} #{c(:bold)}#{json['http_method']}#{c(:reset)} #{path}"
        when 'Request completed'
          path = strip_namespace(json['path'])
          sc = json['status_code'].to_i
          sc_color = status_color(sc)
          puts "#{prefix_str}#{c(:gray)}#{timestamp}#{c(:reset)} " \
               "#{c(:cyan)}Completed#{c(:reset)} #{c(sc_color)}#{sc}#{c(:reset)} #{path}"
        else
          level = json['level']
          level_col = level_color_for(level)
          puts "#{prefix_str}#{c(:gray)}#{timestamp}#{c(:reset)} #{level_col}#{level}#{c(:reset)} #{message}" if level
        end
      end

      def format_aws_error(json, prefix: nil)
        prefix_str = prefix ? "#{c(:blue)}[#{prefix}]#{c(:reset)} " : ''
        puts "#{prefix_str}  #{c(:dim)}Error Type:#{c(:reset)}    #{c(:red)}#{json['errorType']}#{c(:reset)}"
        puts "#{prefix_str}  #{c(:dim)}Error Message:#{c(:reset)} #{json['errorMessage']}"
        return unless json['stackTrace'].is_a?(Array)

        puts "#{prefix_str}  #{c(:dim)}Stack Trace:#{c(:reset)}"
        json['stackTrace'].first(20).each do |line|
          if line.match?(%r{(controllers|models|lib|helpers)/})
            puts "#{prefix_str}    #{c(:yellow)}→#{c(:reset)} #{line}"
          elsif line.include?('/var/task/')
            puts "#{prefix_str}    #{c(:cyan)}→#{c(:reset)} #{line}"
          else
            puts "#{prefix_str}    #{c(:gray)}  #{line}#{c(:reset)}"
          end
        end
      end

      def format_backtrace(backtrace)
        return unless backtrace.is_a?(Array) && backtrace.any?

        puts "  #{c(:dim)}Backtrace:#{c(:reset)}"
        backtrace.first(15).each do |line|
          if line.match?(%r{(controllers|models|lib|helpers)/})
            puts "    #{c(:yellow)}→#{c(:reset)} #{line}"
          else
            puts "    #{c(:gray)}  #{line}#{c(:reset)}"
          end
        end
      end

      def should_show_level?(level)
        return true unless level

        levels = { 'DEBUG' => 1, 'INFO' => 2, 'WARN' => 3, 'ERROR' => 4 }
        (levels[level] || 0) >= (levels[@level] || 2)
      end

      def level_color_for(level)
        case level
        when 'INFO' then c(:green)
        when 'WARN' then c(:yellow)
        when 'ERROR' then c(:red)
        else c(:gray)
        end
      end

      def status_color(code)
        if code >= 500
          :red
        elsif code >= 400
          :yellow
        else
          :green
        end
      end

      def strip_namespace(path)
        return path unless path

        path.sub(%r{\A/[^/]+}, '')
      end

      def print_header(lambda_name)
        full_name = "#{@app_name}-#{@env}-#{lambda_name}"
        puts "#{c(:cyan)}═══════════════════════════════════════════════════════════════#{c(:reset)}"
        puts "#{c(:bold)}Lambda Logs: #{c(:magenta)}#{full_name}#{c(:reset)}"
        puts "#{c(:cyan)}═══════════════════════════════════════════════════════════════#{c(:reset)}"
      end

      def format_timestamp(epoch_ms)
        return '' unless epoch_ms

        Time.at(epoch_ms / 1000.0).strftime('%H:%M:%S')
      end

      def extract_time_from_line(line)
        match = line.match(/\A(\d{4}-\d{2}-\d{2}T[\d:]+)/)
        match ? match[1].split('T').last : ''
      end

      def parse_since(value)
        num = value.to_i
        case value
        when /h\z/ then num * 60 * 60 * 1000
        when /m\z/ then num * 60 * 1000
        when /s\z/ then num * 1000
        else num * 60 * 1000
        end
      end

      def parse_json(str)
        JSON.parse(str)
      rescue StandardError
        nil
      end

      def find_infra_dir
        candidates = %w[infrastructure infra]
        candidates.map { |d| File.join(Dir.pwd, d) }.find { |d| Dir.exist?(d) }
      end

      def c(name)
        @color ? COLORS[name].to_s : ''
      end
    end
  end
end
