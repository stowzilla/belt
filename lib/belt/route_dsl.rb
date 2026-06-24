# frozen_string_literal: true

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
      if actions.include?(:show)
        @gateway.send(:add_route, :get, "#{@prefix}/#{resource_name}/{#{param_name}}",
                      resource_options)
      end
      if actions.include?(:update)
        @gateway.send(:add_route, :put, "#{@prefix}/#{resource_name}/{#{param_name}}",
                      resource_options)
      end
      return unless actions.include?(:destroy)

      @gateway.send(:add_route, :delete, "#{@prefix}/#{resource_name}/{#{param_name}}",
                    resource_options)
    end

    def member(&)
      MemberCollectionBuilder.new(@gateway, @prefix, @inherited_tables, @inherited_auth).instance_eval(&)
    end

    def collection(&)
      MemberCollectionBuilder.new(@gateway, @collection_prefix, @inherited_tables,
                                  @inherited_auth).instance_eval(&)
    end

    %i[get post put delete patch].each do |method|
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

    %i[get post put delete patch].each do |method|
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

    def lambda(name, &)
      previous_context = @current_lambda_context
      @current_lambda_context = name.to_sym
      instance_eval(&) if block_given?
      @current_lambda_context = previous_context
    end

    %i[get post put delete patch].each do |method|
      define_method(method) do |path, options = {}|
        add_route(method, path, options)
      end
    end

    def resources(name, options = {}, &)
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

      return unless block_given?

      collection_prefix = "/#{resource_name}"
      member_prefix = "/#{resource_name}/{#{param_name}}"
      resource_tables = Array(options[:tables] || [])
      inherited_tables = (@default_tables + resource_tables).uniq
      inherited_auth = options[:auth] || @default_auth
      nested_builder = NestedResourceBuilder.new(self, member_prefix, collection_prefix,
                                                 inherited_tables: inherited_tables,
                                                 inherited_auth: inherited_auth)
      nested_builder.instance_eval(&)
    end

    def resource(name, options = {})
      resource_name = name.to_s
      actions = determine_actions(options, default: %i[show update destroy])
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

    def determine_actions(options, default: %i[index create show update destroy])
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

  # Application object providing Rails-style `Belt.application.routes.draw` DSL.
  class Application
    class Routes
      attr_reader :dsl

      def initialize
        @dsl = RouteDSL.new
      end

      def draw(&)
        instance_eval(&) if block_given?
        @dsl
      end

      def namespace(name, options = {}, &)
        gateway = Belt::ApiGateway.new(name, options)
        RouteBuilder.new(gateway).instance_eval(&) if block_given?
        @dsl.api_gateways << gateway
      end
    end

    def routes
      Routes.new
    end

    def schema
      @schema_builder ||= SchemaBuilder.new
    end

    class RouteBuilder
      def initialize(gateway)
        @gateway = gateway
        @scope_prefix = ''
        @scope_module = nil
        @scope_auth = nil
        @scope_tables = []
        @scope_controller = nil
      end

      def scope(options = {}, &)
        previous_prefix = @scope_prefix
        previous_module = @scope_module
        previous_auth = @scope_auth
        previous_tables = @scope_tables
        previous_controller = @scope_controller

        @scope_prefix = options[:path] || @scope_prefix
        @scope_module = options[:module] || @scope_module
        @scope_auth = options[:auth] || @scope_auth
        @scope_tables = (@scope_tables + Array(options[:tables] || [])).uniq
        @scope_controller = options[:controller] || @scope_controller

        instance_eval(&) if block_given?

        @scope_prefix = previous_prefix
        @scope_module = previous_module
        @scope_auth = previous_auth
        @scope_tables = previous_tables
        @scope_controller = previous_controller
      end

      %i[get post put delete patch].each do |method|
        define_method(method) do |path, options = {}|
          full_path = build_path(path)
          route_options = options.dup
          route_options[:lambda] ||= @scope_module if @scope_module
          route_options[:auth] ||= @scope_auth if @scope_auth
          route_options[:controller] ||= @scope_controller if @scope_controller
          if @scope_tables.any? || route_options[:tables]
            route_options[:tables] =
              (@scope_tables + Array(route_options[:tables] || [])).uniq
          end
          @gateway.send(method, full_path, route_options)
        end
      end

      def resources(name, options = {}, &)
        options = apply_scope_options(options)
        @gateway.resources(name, options, &)
      end

      def resource(name, options = {})
        options = apply_scope_options(options)
        @gateway.resource(name, options)
      end

      def lambda(name, &)
        name
      end

      def mount(mountable, options = {})
        prefix = options[:at]&.to_s&.gsub(%r{^/|/$}, '') || ''
        extra_tables = Array(options[:tables] || [])
        auth_override = options[:auth]

        route_definitions = mountable.respond_to?(:routes) ? mountable.routes : []

        route_definitions.each do |route_def|
          method = route_def[:method].to_sym
          path = route_def[:path].to_s.gsub(/:([a-zA-Z_]\w*)/) { "{#{::Regexp.last_match(1)}}" }

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
  end

  class << self
    def application
      @application ||= Application.new
    end
  end

  # Minimal RouteDSL for legacy api_gateway style
  class RouteDSL
    attr_reader :api_gateways

    def initialize
      @api_gateways = []
    end

    def api_gateway(name, options = {}, &)
      gateway = Belt::ApiGateway.new(name, options)
      gateway.instance_eval(&) if block_given?
      @api_gateways << gateway
    end

    def self.load_from_file(filename)
      dsl = new
      dsl.instance_eval(File.read(filename), filename)
      dsl
    end
  end

  # SchemaBuilder captures request and response model definitions from schema.tf.rb
  class SchemaBuilder
    SUPPORTED_TYPES = %i[string number integer boolean array object map list].freeze

    attr_reader :request_models, :response_models

    def initialize
      @request_models = {}
      @response_models = {}
    end

    def define(&)
      instance_eval(&) if block_given?
      self
    end

    alias draw define

    def request(name, &)
      builder = RequestModelBuilder.new(name)
      builder.instance_eval(&) if block_given?
      @request_models[name] = builder
    end

    def model(name, &)
      builder = ResponseModelBuilder.new(name)
      builder.instance_eval(&) if block_given?
      @response_models[name] = builder
    end

    def to_h
      {
        request_models: @request_models.transform_values(&:to_h),
        response_models: @response_models.transform_values(&:to_h)
      }
    end
  end

  class RequestModelBuilder
    SUPPORTED_TYPES = %i[string number integer boolean array object map list].freeze

    attr_reader :name, :fields

    def initialize(name)
      @name = name
      @fields = []
    end

    SUPPORTED_TYPES.each do |type|
      define_method(type) do |field_name, options = {}|
        @fields << { name: field_name, type: type, required: options[:required] == true }
      end
    end

    def to_h
      {
        name: @name.to_s,
        properties: fields_to_properties,
        required: @fields.select { |f| f[:required] }.map { |f| f[:name].to_s }
      }
    end

    private

    def fields_to_properties
      @fields.each_with_object({}) do |field, hash|
        hash[field[:name].to_s] = { type: map_type(field[:type]) }
      end
    end

    def map_type(dsl_type)
      case dsl_type
      when :map then 'object'
      when :list then 'array'
      else dsl_type.to_s
      end
    end
  end

  class ResponseModelBuilder
    SUPPORTED_TYPES = %i[string number integer boolean array object map list].freeze

    attr_reader :name, :contexts, :fields

    def initialize(name)
      @name = name
      @contexts = {}
      @fields = []
    end

    SUPPORTED_TYPES.each do |type|
      define_method(type) do |field_name, options = {}|
        @fields << { name: field_name, type: type }
      end
    end

    def context(name, &)
      builder = ContextBuilder.new(name)
      builder.instance_eval(&) if block_given?
      @contexts[name] = builder
    end

    def to_h
      result = { name: @name.to_s, contexts: @contexts.transform_values(&:to_h) }
      result[:properties] = fields_to_properties unless @fields.empty?
      result
    end

    private

    def fields_to_properties
      @fields.each_with_object({}) do |field, hash|
        hash[field[:name].to_s] = { type: map_type(field[:type]) }
      end
    end

    def map_type(dsl_type)
      case dsl_type
      when :map then 'object'
      when :list then 'array'
      else dsl_type.to_s
      end
    end
  end

  class ContextBuilder
    SUPPORTED_TYPES = %i[string number integer boolean array object map list].freeze

    attr_reader :name, :fields

    def initialize(name)
      @name = name
      @fields = []
    end

    SUPPORTED_TYPES.each do |type|
      define_method(type) do |field_name, options = {}|
        @fields << { name: field_name, type: type }
      end
    end

    def to_h
      { name: @name.to_s, properties: fields_to_properties }
    end

    private

    def fields_to_properties
      @fields.each_with_object({}) do |field, hash|
        hash[field[:name].to_s] = { type: map_type(field[:type]) }
      end
    end

    def map_type(dsl_type)
      case dsl_type
      when :map then 'object'
      when :list then 'array'
      else dsl_type.to_s
      end
    end
  end
end
