# frozen_string_literal: true

require "json"
require_relative "helpers/cors_origin"

module Belt
  # Routes incoming requests to controllers based on a route manifest.
  #
  # Usage:
  #   ROUTER = Belt::ActionRouter.new(routes: MY_ROUTES, namespace: "api")
  #   response = ROUTER.route(event: event, body: body)
  #
  class ActionRouter
    class RouteNotFound < StandardError; end

    def initialize(routes:, namespace:)
      @namespace = namespace.to_s
      @namespace_module_name = "#{@namespace.split('_').map(&:capitalize).join}Controllers"
      @routes = build_route_table(routes)
    end

    def route(event:, body:)
      method = event["httpMethod"]
      full_path = event["path"]
      match_path = strip_namespace_prefix(full_path)

      route_info = find_route(method, match_path)

      unless route_info
        Belt::Observability::Logger.instance&.warn("Route not found", method: method, path: full_path)
        return error_response("Not found", 404, event)
      end

      path_params = extract_path_params(route_info[:pattern], match_path)
      event["pathParameters"] = (event["pathParameters"] || {}).merge(path_params)

      dispatch_to_controller(route_info, event, body)
    end

    def find_route(method, path)
      @routes.find { |r| r[:verb] == method && r[:regex].match?(path) }
    end

    def extract_path_params(pattern, actual_path)
      param_names = pattern.scan(/\{([^}]+)\}/).flatten
      return {} if param_names.empty?

      match = path_to_regex(pattern).match(actual_path)
      return {} unless match

      param_names.zip(match.captures).to_h
    end

    private

    def strip_namespace_prefix(path)
      return "/" if path.nil?

      prefix = "/#{@namespace}"
      if path.start_with?(prefix)
        stripped = path.sub(prefix, "")
        stripped.empty? ? "/" : stripped
      else
        path
      end
    end

    def build_route_table(routes)
      routes.map { |r| build_route_entry(r) }
            .sort_by { |r| route_specificity(r[:pattern]) }
    end

    def route_specificity(pattern)
      segments = pattern.split("/").reject(&:empty?)
      param_count = segments.count { |s| s.start_with?("{") }
      [param_count, -segments.length, pattern]
    end

    def build_route_entry(route)
      {
        verb: route[:verb] || route["verb"],
        pattern: route[:path] || route["path"],
        regex: path_to_regex(route[:path] || route["path"]),
        controller: route[:controller] || route["controller"],
        action: route[:action] || route["action"]
      }
    end

    def path_to_regex(pattern)
      segments = pattern.split("/")
      regex_parts = segments.map do |seg|
        if seg =~ /\A\{[^}]+\}\z/
          "([^/]+)"
        else
          Regexp.escape(seg)
        end
      end

      Regexp.new("\\A#{regex_parts.join('/')}\\z")
    end

    def dispatch_to_controller(route_info, event, body)
      controller_class = resolve_controller(route_info[:controller])
      controller = controller_class.new(event: event, body: body)

      controller_name = controller_class.name.split("::").last.gsub("Controller", "")
      Belt::Observability::Logger.instance&.info("Processing by #{controller_name}##{route_info[:action]}")

      controller.dispatch(route_info[:action].to_sym)
    end

    def resolve_controller(controller_name)
      # Try namespace module first (app's own controllers)
      begin
        namespace_module = Object.const_get(@namespace_module_name)
        return resolve_from_module(namespace_module, controller_name)
      rescue NameError
        # Fall through to controller_paths lookup
      end

      # Scan controller_paths (gem-provided controllers via convention)
      resolve_from_paths(controller_name)
    end

    def resolve_from_module(namespace_module, controller_name)
      if controller_name.include?("/")
        parts = controller_name.split("/")
        parent = namespace_module.const_get(parts[0].split("_").map(&:capitalize).join)
        parent.const_get("#{parts[1].split('_').map(&:capitalize).join}Controller")
      else
        namespace_module.const_get("#{controller_name.split('_').map(&:capitalize).join}Controller")
      end
    end

    def resolve_from_paths(controller_name)
      file_name = if controller_name.include?("/")
                    "#{controller_name}_controller.rb"
                  else
                    "#{controller_name}_controller.rb"
                  end

      Belt.controller_paths.each do |path|
        full_path = File.join(path, file_name)
        if File.exist?(full_path)
          require full_path
          # After requiring, try to find the constant
          class_name = controller_name.split(/[_\/]/).map(&:capitalize).join + "Controller"
          return Object.const_get(class_name) if Object.const_defined?(class_name)
        end
      end

      raise Belt::ActionNotFound, "Controller not found: #{controller_name}"
    end

    def error_response(message, status_code, event = nil)
      origin = Belt::Helpers::CorsOrigin.resolve_origin(Belt::Helpers::CorsOrigin.origin_from_event(event))
      headers = {
        "Access-Control-Allow-Headers" => "Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token",
        "Access-Control-Allow-Methods" => "GET,POST,PUT,DELETE,PATCH,OPTIONS",
        "Content-Type" => "application/json"
      }
      headers["Access-Control-Allow-Origin"] = origin if origin
      { statusCode: status_code, headers: headers, body: JSON.generate(error: message) }
    end
  end
end
