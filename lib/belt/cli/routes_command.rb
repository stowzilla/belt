# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../route_dsl'

module Belt
  module CLI
    class RoutesCommand
      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @options = {}
        parse_options(args)
      end

      def run
        routes_file = find_routes_file
        unless routes_file
          abort "Error: No routes file found. Expected infrastructure/routes.tf.rb"
        end

        dsl = load_routes(routes_file)
        routes = collect_routes(dsl)
        routes = apply_grep(routes) if @options[:grep]

        case @options[:format]
        when 'json'
          puts JSON.pretty_generate(routes: routes)
        else
          output_concise(routes)
        end
      end

      private

      def parse_options(args)
        OptionParser.new do |opts|
          opts.banner = "Usage: belt routes [options]"

          opts.on("-g", "--grep PATTERN", "Filter routes matching pattern") do |pattern|
            @options[:grep] = pattern
          end

          opts.on("-f", "--format FORMAT", "Output format: concise (default), json") do |format|
            @options[:format] = format
          end

          opts.on("-h", "--help", "Show this help") do
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
        content = File.read(file)
        if content.include?('TerraDispatch.routes.draw')
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
            routes << {
              verb: route.method,
              path: normalize_path(route.path),
              gateway: gateway.name,
              lambda: route.lambda.to_s,
              controller: infer_controller(route, gateway),
              action: infer_action(route, gateway),
              auth: route.auth.to_s
            }
          end
        end
        routes.sort_by { |r| [r[:gateway], r[:path], verb_order(r[:verb])] }
      end

      def normalize_path(path)
        path = "/#{path}" unless path.start_with?('/')
        # Convert :param to {param} and :id to {resource_id}
        path.gsub(%r{/([a-zA-Z_][a-zA-Z0-9_]*?)/:id(/|$)}) do
          resource = ::Regexp.last_match(1)
          trailing = ::Regexp.last_match(2)
          singular = singularize(resource)
          "/#{resource}/{#{singular}_id}#{trailing}"
        end.gsub(/:([a-zA-Z_][a-zA-Z0-9_]*)/) { "{#{$1}}" }
      end

      def infer_controller(route, gateway)
        return route.controller if route.controller

        segments = route.path.split('/').reject(&:empty?)
        non_param = segments.reject { |s| s.start_with?(':', '{') }
        return gateway.name if non_param.empty?

        # Nested resource: parent/{id}/child → "parent/child"
        if route.resource? && nested_resource?(segments)
          return non_param.map { |s| s.gsub('-', '_') }.join('/')
        end

        if route.resource?
          non_param.first.gsub('-', '_')
        elsif non_param.length == 1 && segments.length == 1
          route.lambda.to_s != gateway.name ? route.lambda.to_s : gateway.name
        else
          non_param.first.gsub('-', '_')
        end
      end

      def infer_action(route, gateway)
        return route.action if route.action

        segments = route.path.split('/').reject(&:empty?)
        non_param = segments.reject { |s| s.start_with?(':', '{') }
        has_id = segments.any? { |s| s.start_with?(':', '{') }
        last_is_param = segments.last&.start_with?(':', '{')
        verb = route.method

        if route.singular_resource?
          case verb
          when 'GET' then 'show'
          when 'PUT', 'PATCH' then 'update'
          when 'DELETE' then 'destroy'
          when 'POST' then 'create'
          else 'show'
          end
        elsif route.plural_resource? && nested_resource?(segments)
          # Nested resource: check for child ID param
          child_idx = segments.rindex { |s| !s.start_with?(':', '{') }
          has_child_id = child_idx && segments[(child_idx + 1)..]&.any? { |s| s.start_with?(':', '{') }
          restful_action(verb, has_child_id || false)
        elsif route.plural_resource?
          restful_action(verb, has_id && last_is_param)
        elsif non_param.length <= 1 && !has_id
          non_param.first&.gsub('-', '_') || 'index'
        elsif non_param.length > 1
          non_param.last.gsub('-', '_')
        else
          restful_action(verb, has_id && last_is_param)
        end
      end

      def nested_resource?(segments)
        # Pattern: resource/{param}/resource...
        segments.length >= 3 &&
          !segments[0].start_with?(':', '{') &&
          segments[1]&.start_with?(':', '{') &&
          !segments[2]&.start_with?(':', '{')
      end

      def restful_action(verb, is_member)
        case [verb, is_member]
        when ['GET', false] then 'index'
        when ['GET', true] then 'show'
        when ['POST', false] then 'create'
        when ['PUT', true], ['PATCH', true] then 'update'
        when ['DELETE', true] then 'destroy'
        else 'index'
        end
      end

      def apply_grep(routes)
        pattern = Regexp.new(@options[:grep], Regexp::IGNORECASE)
        routes.select do |r|
          r[:path].match?(pattern) ||
            r[:gateway].match?(pattern) ||
            r[:lambda].match?(pattern) ||
            r[:verb].match?(pattern) ||
            r[:controller].match?(pattern) ||
            r[:action].match?(pattern)
        end
      end

      def output_concise(routes)
        return puts("No routes defined.") if routes.empty?

        multi_gateway = routes.map { |r| r[:gateway] }.uniq.length > 1

        verb_w = [routes.map { |r| r[:verb].length }.max, 6].max
        path_w = [routes.map { |r| r[:path].length }.max, 4].max

        if multi_gateway
          gw_w = [routes.map { |r| r[:gateway].length }.max, 7].max
          lam_w = [routes.map { |r| r[:lambda].length }.max, 6].max

          puts "#{'VERB'.ljust(verb_w)}  #{'PATH'.ljust(path_w)}  #{'GATEWAY'.ljust(gw_w)}  #{'LAMBDA'.ljust(lam_w)}  CONTROLLER#ACTION"
          puts "-" * (verb_w + path_w + gw_w + lam_w + 20)

          routes.each do |r|
            puts "#{r[:verb].ljust(verb_w)}  #{r[:path].ljust(path_w)}  #{r[:gateway].ljust(gw_w)}  #{r[:lambda].ljust(lam_w)}  #{r[:controller]}##{r[:action]}"
          end
        else
          puts "#{'VERB'.ljust(verb_w)}  #{'PATH'.ljust(path_w)}  CONTROLLER#ACTION"
          puts "-" * (verb_w + path_w + 30)

          routes.each do |r|
            puts "#{r[:verb].ljust(verb_w)}  #{r[:path].ljust(path_w)}  #{r[:controller]}##{r[:action]}"
          end
        end
      end

      def verb_order(verb)
        { 'GET' => 0, 'POST' => 1, 'PUT' => 2, 'PATCH' => 3, 'DELETE' => 4 }[verb] || 99
      end

      def singularize(word)
        if word.end_with?('ies')
          word[0..-4] + 'y'
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
