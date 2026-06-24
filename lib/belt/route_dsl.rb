# frozen_string_literal: true

require 'set'

module Belt
  # DSL for defining API Gateway routes.
  # Ported from terraform-provider-conveyor-belt/scripts/lib/route_dsl.rb
  # so that `belt routes` can parse routes.tf.rb without external dependencies.

  class Route
    attr_reader :method, :path, :auth, :lambda, :cors, :tables, :route_type,
                :controller, :action, :request_model, :response_model, :response_context

    def initialize(method, path, options = {})
      @method = method.to_s.upcase
      @path = normalize_path(path)
      @auth = options[:auth]
      @lambda = options[:lambda]
      @cors = options.fetch(:cors, true)
      @tables = options[:tables] || []
      @route_type = options[:route_type] || :action
      @controller = options[:controller]
      @action = options[:action]
      @request_model = options[:request_model]&.to_s
      @response_model = options[:response_model]&.to_s
      @response_context = options[:response_context]&.to_s
    end

    def resource?
      @route_type == :resource || @route_type == :resources
    end

    def singular_resource?
      @route_type == :resource
    end

    def plural_resource?
      @route_type == :resources
    end

    def action?
      @route_type == :action
    end

    private

    def normalize_path(path)
      path = "/#{path}" unless path.start_with?('/')
      path
    end
  end

  class NestedResourceBuilder
    def initialize(gateway, prefix, collection_prefix, inherited_tables: [], inherited_auth: nil)
      @gateway = gateway
      @prefix = prefix
      @collection_prefix = collection_prefix
      @inherited_tables = inherited_tables
      @inherited_auth = inherited_auth
    end

    def resources(name, options = {})
      resource_name = name.to_s
      singular = @gateway.send(:singularize, resource_name)
      param_name = options[:param] || "#{singular}_id"
      options = merge_inherited_options(options)
      options = @gateway.send(:auto_infer_tables, resource_name, options)
      resource_options = options.merge(route_type: :resources)
      actions = @gateway.send(:determine_actions, options)

      @gateway.send(:add_route, :get, "#{@prefix}/#{resource_name}", resource_options) if actions.include?(:index)
      @gateway.send(:add_route, :post, "#{@prefix}/#{resource_name}", resource_options) if actions.include?(:create)
      @gateway.send(:add_route, :get, "#{@prefix}/#{resource_name}/{#{param_name}}", resource_options) if actions.include?(:show)
      @gateway.send(:add_route, :put, "#{@prefix}/#{resource_name}/{#{param_name}}", resource_options) if actions.include?(:update)
      @gateway.send(:add_route, :delete, "#{@prefix}/#{resource_name}/{#{param_name}}", resource_options) if actions.include?(:destroy)
    end

    def member(&block)
      MemberCollectionBuilder.new(@gateway, @prefix, @inherited_tables, @inherited_auth).instance_eval(&block)
    end

    def collection(&block)
      MemberCollectionBuilder.new(@gateway, @collection_prefix, @inherited_tables, @inherited_auth).instance_eval(&block)
    end

    [:get, :post, :put, :delete, :patch].each do |method|
      define_method(method) do |path, options = {}|
        full_path = options[:on] == :collection ? "#{@collection_prefix}#{path}" : "#{@prefix}#{path}"
        options = merge_inherited_options(options)
        route_options = options.reject { |k, _| k == :on }
        @gateway.send(:add_route, method, full_path, route_options)
      end
    end

    private

    def merge_inherited_options(options)
      result = options.dup
      if @inherited_tables.any?
        explicit_tables = Array(result[:tables] || [])
        result[:tables] = (@inherited_tables + explicit_tables).uniq
      end
      result[:auth] ||= @inherited_auth if @inherited_auth
      result
    end
  end

  class MemberCollectionBuilder
    def initialize(gateway, prefix, inherited_tables, inherited_auth)
      @gateway = gateway
      @prefix = prefix
      @inherited_tables = inherited_tables
      @inherited_auth = inherited_auth
    end

    [:get, :post, :put, :delete, :patch].each do |method|
      define_method(method) do |path, options = {}|
        full_path = "#{@prefix}#{path}"
        options = merge_inherited_options(options)
        @gateway.send(:add_route, method, full_path, options)
      end
    end

    private

    def merge_inherited_options(options)
      result = options.dup
      if @inherited_tables.any?
        explicit_tables = Array(result[:tables] || [])
        result[:tables] = (@inherited_tables + explicit_tables).uniq
      end
      result[:auth] ||= @inherited_auth if @inherited_auth
      result
    end
  end

  class ApiGateway
    attr_reader :name, :routes, :default_auth, :default_lambda, :default_cors, :default_tables

    def initialize(name, options = {})
      @name = name.to_s
      @routes = []
      @default_auth = options[:auth] || :cognito
      @default_lambda = options[:lambda] || name
      @default_cors = options.fetch(:cors, true)
      @default_tables = Array(options[:tables] || [])
      @current_lambda_context = nil
    end

    def lambda(name, &block)
      previous_context = @current_lambda_context
      @current_lambda_context = name.to_sym
      instance_eval(&block) if block_given?
      @current_lambda_context = previous_context
    end

    [:get, :post, :put, :delete, :patch].each do |method|
      define_method(method) do |path, options = {}|
        add_route(method, path, options)
      end
    end

    def resources(name, options = {}, &block)
      resource_name = name.to_s
      singular = singularize(resource_name)
      param_name = options[:param] || "#{singular}_id"
      options = auto_infer_tables(resource_name, options)
      resource_options = options.merge(route_type: :resources)
      actions = determine_actions(options)

      add_route(:get, "/#{resource_name}", resource_options) if actions.include?(:index)
      add_route(:post, "/#{resource_name}", resource_options) if actions.include?(:create)
      add_route(:get, "/#{resource_name}/{#{param_name}}", resource_options) if actions.include?(:show)
      add_route(:put, "/#{resource_name}/{#{param_name}}", resource_options) if actions.include?(:update)
      add_route(:delete, "/#{resource_name}/{#{param_name}}", resource_options) if actions.include?(:destroy)

      if block_given?
        collection_prefix = "/#{resource_name}"
        member_prefix = "/#{resource_name}/{#{param_name}}"
        resource_tables = Array(options[:tables] || [])
        inherited_tables = (@default_tables + resource_tables).uniq
        inherited_auth = options[:auth] || @default_auth
        nested_builder = NestedResourceBuilder.new(self, member_prefix, collection_prefix,
                                                   inherited_tables: inherited_tables,
                                                   inherited_auth: inherited_auth)
        nested_builder.instance_eval(&block)
      end
    end

    def resource(name, options = {})
      resource_name = name.to_s
      actions = determine_actions(options, default: [:show, :update, :destroy])
      resource_options = options.merge(route_type: :resource)

      add_route(:get, "/#{resource_name}", resource_options) if actions.include?(:show)
      add_route(:put, "/#{resource_name}", resource_options) if actions.include?(:update)
      add_route(:delete, "/#{resource_name}", resource_options) if actions.include?(:destroy)
      add_route(:post, "/#{resource_name}", resource_options) if actions.include?(:create)
    end

    private

    def add_route(method, path, options = {})
      lambda_to_use = options[:lambda] || @current_lambda_context || @default_lambda
      route_tables = Array(options[:tables] || [])
      merged_tables = (@default_tables + route_tables).uniq

      controller = options[:controller]
      action = options[:action]
      if options[:to]
        parts = options[:to].to_s.split('#')
        if parts.length == 2
          controller ||= parts[0]
          action ||= parts[1]
        end
      end

      route_options = {
        auth: options[:auth] || @default_auth,
        lambda: lambda_to_use,
        cors: options.fetch(:cors, @default_cors),
        tables: merged_tables,
        route_type: options[:route_type] || :action,
        controller: controller,
        action: action,
        request_model: options[:request_model],
        response_model: options[:response_model],
        response_context: options[:response_context]
      }

      @routes << Belt::Route.new(method, path, route_options)
    end

    def auto_infer_tables(resource_name, options)
      return options if options.key?(:tables)

      options.merge(tables: [resource_name.to_sym])
    end

    def determine_actions(options, default: [:index, :create, :show, :update, :destroy])
      if options[:only]
        Array(options[:only])
      elsif options[:except]
        default - Array(options[:except])
      else
        default
      end
    end

    def singularize(word)
      if word.end_with?('ies')
        word[0..-4] + 'y'
      elsif word.end_with?('xes') || word.end_with?('zes') || word.end_with?('ses')
        word[0..-3]
      elsif word.end_with?('ches') || word.end_with?('shes')
        word[0..-3]
      elsif word.end_with?('s') && !word.end_with?('ss')
        word[0..-2]
      else
        word
      end
    end
  end

  # TerraDispatch-compatible wrapper so routes.tf.rb files work unchanged.
  module TerraDispatch
    class Routes
      attr_reader :dsl

      def initialize
        @dsl = RouteDSL.new
      end

      def draw(&block)
        instance_eval(&block) if block_given?
        @dsl
      end

      def namespace(name, options = {}, &block)
        gateway = Belt::ApiGateway.new(name, options)
        RouteBuilder.new(gateway).instance_eval(&block) if block_given?
        @dsl.api_gateways << gateway
      end
    end

    class RouteBuilder
      def initialize(gateway)
        @gateway = gateway
        @scope_prefix = ''
        @scope_module = nil
        @scope_auth = nil
        @scope_tables = []
      end

      def scope(options = {}, &block)
        previous_prefix = @scope_prefix
        previous_module = @scope_module
        previous_auth = @scope_auth
        previous_tables = @scope_tables

        @scope_prefix = options[:path] || @scope_prefix
        @scope_module = options[:module] || @scope_module
        @scope_auth = options[:auth] || @scope_auth
        @scope_tables = (@scope_tables + Array(options[:tables] || [])).uniq

        instance_eval(&block) if block_given?

        @scope_prefix = previous_prefix
        @scope_module = previous_module
        @scope_auth = previous_auth
        @scope_tables = previous_tables
      end

      [:get, :post, :put, :delete, :patch].each do |method|
        define_method(method) do |path, options = {}|
          full_path = build_path(path)
          route_options = options.dup
          route_options[:lambda] ||= @scope_module if @scope_module
          route_options[:auth] ||= @scope_auth if @scope_auth
          route_options[:tables] = (@scope_tables + Array(route_options[:tables] || [])).uniq if @scope_tables.any? || route_options[:tables]
          @gateway.send(method, full_path, route_options)
        end
      end

      def resources(name, options = {}, &block)
        options = apply_scope_options(options)
        @gateway.resources(name, options, &block)
      end

      def resource(name, options = {})
        options = apply_scope_options(options)
        @gateway.resource(name, options)
      end

      def lambda(name, &block)
        @gateway.lambda(name, &block)
      end

      def mount(mountable, options = {})
        prefix = options[:at]&.to_s&.gsub(%r{^/|/$}, '') || ''
        extra_tables = Array(options[:tables] || [])
        auth_override = options[:auth]

        route_definitions = mountable.respond_to?(:routes) ? mountable.routes : []

        route_definitions.each do |route_def|
          method = route_def[:method].to_sym
          path = route_def[:path].to_s.gsub(/:([a-zA-Z_]\w*)/) { "{#{$1}}" }

          full_path = prefix.empty? ? path : "/#{prefix}#{path}"
          full_path = full_path.chomp('/') unless full_path == '/'
          full_path = build_path(full_path)

          route_options = (route_def[:options] || {}).dup
          route_options[:tables] = (extra_tables + Array(route_options[:tables] || [])).uniq
          route_options[:auth] = auth_override if auth_override
          route_options[:auth] ||= @scope_auth if @scope_auth
          route_options[:tables] = (@scope_tables + route_options[:tables]).uniq if @scope_tables.any?
          route_options[:controller] ||= prefix.gsub('-', '_') unless prefix.empty?
          stripped = path.gsub(%r{^/|/$}, '')
          route_options[:action] ||= stripped.empty? ? 'index' : stripped.gsub('-', '_')

          @gateway.send(method, full_path, route_options)
        end
      end

      private

      def build_path(path)
        @scope_prefix.empty? ? path : "/#{@scope_prefix}#{path}"
      end

      def apply_scope_options(options)
        result = options.dup
        result[:auth] ||= @scope_auth if @scope_auth
        result[:lambda] ||= @scope_module if @scope_module
        result[:tables] = (@scope_tables + Array(result[:tables] || [])).uniq if @scope_tables.any? || result[:tables]
        result
      end
    end

    def self.routes
      Routes.new
    end

    def self.schema
      @schema_builder ||= SchemaBuilder.new
    end
  end

  # Minimal RouteDSL for legacy api_gateway style
  class RouteDSL
    attr_reader :api_gateways

    def initialize
      @api_gateways = []
    end

    def api_gateway(name, options = {}, &block)
      gateway = Belt::ApiGateway.new(name, options)
      gateway.instance_eval(&block) if block_given?
      @api_gateways << gateway
    end

    def self.load_from_file(filename)
      dsl = new
      dsl.instance_eval(File.read(filename), filename)
      dsl
    end
  end

  # Minimal SchemaBuilder so schema.tf.rb can be loaded without error
  class SchemaBuilder
    def initialize
      @request_models = {}
      @response_models = {}
    end

    def define(&block)
      instance_eval(&block) if block_given?
      self
    end

    def request(name, &block) = nil
    def model(name, &block) = nil

    def to_h
      { request_models: @request_models, response_models: @response_models }
    end
  end
end
