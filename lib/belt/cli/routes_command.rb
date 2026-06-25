# frozen_string_literal: true

require 'json'
require 'optparse'
require 'fileutils'
require_relative '../route_dsl'
require_relative '../table_inference'
require_relative 'routes_command/schema_loader'
require_relative 'routes_command/route_inference'

module Belt
  module CLI
    class RoutesCommand
      include SchemaLoader
      include RouteInference

      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @options = {}
        parse_options(args)
      end

      def run
        routes_file = find_routes_file
        abort 'Error: No routes file found. Expected infrastructure/routes.tf.rb' unless routes_file

        dsl = load_routes(routes_file)
        @table_inference = TableInference.new(@options[:tables_file])
        routes = collect_routes(dsl)
        routes = apply_grep(routes) if @options[:grep]

        warn 'Warning: --output-dir has no effect without --namespace' if @options[:output_dir] && !@options[:namespace]

        if @options[:namespace]
          output_ruby(routes, @options[:namespace], routes_file)
        elsif @options[:format] == 'json'
          output = { routes: routes }
          models = load_schema_models(routes_file)
          output[:models] = models if models.any?
          puts JSON.pretty_generate(output)
        else
          output_concise(routes)
        end
      end

      private

      def parse_options(args)
        OptionParser.new do |opts|
          opts.banner = 'Usage: belt routes [options]'

          opts.on('-g', '--grep PATTERN', 'Filter routes matching pattern') do |pattern|
            @options[:grep] = pattern
          end

          opts.on('-f', '--format FORMAT', 'Output format: concise (default), json') do |format|
            @options[:format] = format
          end

          opts.on('--namespace NAMESPACE', 'Generate Ruby route files for NAMESPACE (or "all")') do |ns|
            @options[:namespace] = ns
          end

          opts.on('--output-dir DIR', 'Output directory for generated files') do |dir|
            @options[:output_dir] = dir
          end

          opts.on('--schema FILE', 'Path to schema.tf.rb for model definitions') do |file|
            @options[:schema_file] = file
          end

          opts.on('--tables-file FILE', 'Path to Terraform file with DynamoDB table definitions') do |file|
            @options[:tables_file] = file
          end

          opts.on('-h', '--help', 'Show this help') do
            puts opts
            exit
          end
        end.parse!(args)
      end

      def find_routes_file
        path = 'infrastructure/routes.tf.rb'
        File.exist?(path) ? path : nil
      end

      def load_routes(file)
        # Reset schema builder for clean state
        Belt.instance_variable_set(:@application, nil)

        content = File.read(file)
        if content.include?('Belt.application.routes.draw')
          binding_context = binding
          eval(content, binding_context, file) # rubocop:disable Security/Eval
        else
          Belt::RouteDSL.load_from_file(file)
        end
      end

      def collect_routes(dsl)
        routes = []
        dsl.api_gateways.each do |gateway|
          gateway.routes.each do |route|
            routes << build_route_hash(route, gateway)
          end
        end
        routes.sort_by { |r| route_specificity(r[:path], r[:verb]) }
      end

      def build_route_hash(route, gateway)
        hash = {
          name: extract_route_name(route.path),
          verb: route.method,
          path: normalize_path(route.path),
          gateway: gateway.name,
          lambda: route.lambda.to_s,
          controller: infer_controller(route, gateway),
          action: infer_action(route, gateway),
          auth: route.auth.to_s,
          tables: get_route_tables(route),
          request_model: route.request_model.to_s,
          response_model: route.response_model.to_s
        }
        rc = route.response_context.to_s
        hash[:response_context] = rc unless rc.empty?
        hash
      end

      def get_route_tables(route)
        if route.tables.any?
          route.tables.map(&:to_s)
        else
          @table_inference.infer_tables_from_route(route)
        end
      end

      def extract_route_name(path)
        segments = path.split('/').reject(&:empty?)
        return 'root' if segments.empty?

        segments.reject { |s| s.start_with?('{', ':') }
                .map { |s| s.gsub('-', '_') }
                .join('_')
      end

      def output_ruby(routes, namespace, _routes_file)
        output_dir = @options[:output_dir] || File.join(Belt.root, 'lambda/lib/routes')
        FileUtils.mkdir_p(output_dir)
        puts "Writing to #{output_dir}/:"

        if namespace == 'all'
          generate_all_manifests(routes, output_dir)
        else
          # Generate gateway-based manifest (all routes for this gateway)
          filtered = routes.select { |r| r[:gateway] == namespace }
          # Fall back to lambda-based if no gateway match
          filtered = routes.select { |r| r[:lambda] == namespace } if filtered.empty?
          if filtered.empty?
            warn "No routes found for namespace '#{namespace}' - skipping"
            return
          end
          write_ruby_manifest(filtered, namespace, output_dir)
        end
      end

      def generate_all_manifests(routes, output_dir)
        # Gateway-based manifests (primary — used by main Lambda entry points)
        by_gateway = routes.group_by { |r| r[:gateway] }
        by_gateway.each { |gw, gw_routes| write_ruby_manifest(gw_routes, gw, output_dir) }

        # Scoped lambda manifests (where lambda != gateway — separate Lambda functions)
        scoped = routes.reject { |r| r[:lambda] == r[:gateway] }
        by_lambda = scoped.group_by { |r| r[:lambda] }
        by_lambda.each { |lam, lam_routes| write_ruby_manifest(lam_routes, lam, output_dir) }
      end

      def write_ruby_manifest(routes, name, output_dir)
        output_file = File.join(output_dir, "#{name}_routes.rb")
        content = generate_ruby_content(routes, name)
        File.write(output_file, content)
        puts "  ✅ #{name}_routes.rb (#{routes.length} routes)"
      end

      def generate_ruby_content(routes, namespace)
        constant_name = namespace.upcase
        lines = [
          '# frozen_string_literal: true',
          '',
          "# Auto-generated by: belt routes --namespace #{namespace}",
          '# Do not edit manually',
          '',
          'module Routes',
          "  #{constant_name} = ["
        ]

        routes.each_with_index do |route, index|
          lines << '    {'
          lines << "      verb: #{route[:verb].inspect},"
          lines << "      path: #{route[:path].inspect},"
          lines << "      gateway: #{route[:gateway].inspect},"
          lines << "      lambda: #{route[:lambda].inspect},"
          lines << "      controller: #{route[:controller].inspect},"
          lines << "      action: #{route[:action].inspect},"
          lines << "      auth: #{route[:auth].inspect},"
          tables_syms = route[:tables].map { |t| ":#{t}" }.join(', ')
          lines << "      tables: [#{tables_syms}]"
          lines << "    }#{',' if index < routes.length - 1}"
        end

        lines << '  ].freeze'
        lines << 'end'
        lines << ''
        lines.join("\n")
      end

      def normalize_path(path)
        path = "/#{path}" unless path.start_with?('/')
        normalized = path.gsub(%r{/([a-zA-Z_][a-zA-Z0-9_]*?)/:id(/|$)}) do
          resource = ::Regexp.last_match(1)
          trailing = ::Regexp.last_match(2)
          singular = singularize(resource)
          "/#{resource}/{#{singular}_id}#{trailing}"
        end
        normalized.gsub(/:([a-zA-Z_][a-zA-Z0-9_]*)/) { "{#{::Regexp.last_match(1)}}" }
      end

      def apply_grep(routes)
        pattern = Regexp.new(@options[:grep], Regexp::IGNORECASE)
        routes.select do |r|
          r[:path].match?(pattern) ||
            r[:gateway].to_s.match?(pattern) ||
            r[:lambda].match?(pattern) ||
            r[:verb].match?(pattern) ||
            r[:controller].match?(pattern) ||
            r[:action].match?(pattern)
        end
      end

      def output_concise(routes)
        return puts('No routes defined.') if routes.empty?

        multi_gateway = routes.map { |r| r[:gateway] }.uniq.length > 1
        verb_w = [routes.map { |r| r[:verb].length }.max, 6].max
        path_w = [routes.map { |r| r[:path].length }.max, 4].max

        if multi_gateway
          output_concise_multi_gateway(routes, verb_w, path_w)
        else
          output_concise_single_gateway(routes, verb_w, path_w)
        end
      end

      def output_concise_multi_gateway(routes, verb_w, path_w)
        gw_w = [routes.map { |r| r[:gateway].to_s.length }.max, 7].max
        lam_w = [routes.map { |r| r[:lambda].length }.max, 6].max

        header = "#{'VERB'.ljust(verb_w)}  #{'PATH'.ljust(path_w)}  " \
                 "#{'GATEWAY'.ljust(gw_w)}  #{'LAMBDA'.ljust(lam_w)}  CONTROLLER#ACTION"
        puts header
        puts '-' * (verb_w + path_w + gw_w + lam_w + 20)

        routes.each do |r|
          line = "#{r[:verb].ljust(verb_w)}  #{r[:path].ljust(path_w)}  " \
                 "#{r[:gateway].to_s.ljust(gw_w)}  #{r[:lambda].ljust(lam_w)}  " \
                 "#{r[:controller]}##{r[:action]}"
          puts line
        end
      end

      def output_concise_single_gateway(routes, verb_w, path_w)
        puts "#{'VERB'.ljust(verb_w)}  #{'PATH'.ljust(path_w)}  CONTROLLER#ACTION"
        puts '-' * (verb_w + path_w + 30)

        routes.each do |r|
          puts "#{r[:verb].ljust(verb_w)}  #{r[:path].ljust(path_w)}  #{r[:controller]}##{r[:action]}"
        end
      end

      def route_specificity(path, verb)
        segments = path.split('/').reject(&:empty?)
        param_count = segments.count { |s| s.start_with?('{') }
        segment_count = segments.length
        [param_count, -segment_count, path, verb_order(verb)]
      end

      def verb_order(verb)
        { 'GET' => 0, 'POST' => 1, 'PUT' => 2, 'PATCH' => 3, 'DELETE' => 4 }[verb] || 99
      end

      def singularize(word)
        if word.end_with?('ies')
          "#{word[0..-4]}y"
        elsif word.end_with?('ses') || word.end_with?('xes') || word.end_with?('zes')
          word[0..-3]
        elsif word.end_with?('s') && !word.end_with?('ss')
          word[0..-2]
        else
          word
        end
      end
    end
  end
end
