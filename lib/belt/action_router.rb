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
      regex_str = pattern
        .gsub(/\{[^}]+\}/, "___PARAM___")
        .gsub(/[.+?^${}()|\\]/) { |c| "\\#{c}" }
        .gsub("[", '\[').gsub("]", '\]')
        .gsub("___PARAM___", "([^/]+)")

      Regexp.new("^#{regex_str}$")
    end

    def dispatch_to_controller(route_info, event, body)
      controller_class = resolve_controller(route_info[:controller])
      controller = controller_class.new(event: event, body: body)

      controller_name = controller_class.name.split("::").last.gsub("Controller", "")
      Belt::Observability::Logger.instance&.info("Processing by #{controller_name}##{route_info[:action]}")

      controller.dispatch(route_info[:action].to_sym)
    end

    def resolve_controller(controller_name)
      namespace_module = Object.const_get(@namespace_module_name)

      if controller_name.include?("/")
        parts = controller_name.split("/")
        parent = namespace_module.const_get(parts[0].split("_").map(&:capitalize).join)
        parent.const_get("#{parts[1].split('_').map(&:capitalize).join}Controller")
      else
        namespace_module.const_get("#{controller_name.split('_').map(&:capitalize).join}Controller")
      end
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
