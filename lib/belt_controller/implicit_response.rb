# frozen_string_literal: true

module BeltController
  # Rails-like implicit JSON/HTML responses from action assigns / return values.
  # Included by BeltController::Base so the base class stays under Metrics/ClassLength.
  module ImplicitResponse
    # Never auto-serialize these into the JSON body (framework internals).
    FRAMEWORK_IVARS = %i[
      @event @raw_body @params @current_action @current_user_id @user_groups
      @logger @__assigns_before @__response_status
    ].freeze

    private

    # Turn the action return value (or instance-variable assigns) into an API Gateway response.
    #
    # Rails-like behavior for API-first controllers (default_format :json):
    #   def index
    #     @posts = Post.all   # → success_response({ posts: [...] })
    #   end
    #
    # HTML controllers (default_format :html):
    #   def show
    #     @post = Post.find(...)  # → render template views/<ctrl>/show.html.erb
    #   end
    #
    # Explicit responses still win:
    #   success_response(...), error_response(...), html_response(...), render, head
    #
    # Non-200 with implicit body:
    #   def create
    #     @post = Post.create!(...)
    #     response_status :created
    #   end
    def finalize_response(result)
      return result if lambda_response?(result)

      status = @__response_status || 200

      return render(status: status) if self.class.default_format == :html

      # Prefer assigns when present. Ruby assignment returns the RHS, so
      # `@posts = Post.all` would otherwise look like an explicit return value.
      # (Rails ignores the action return value entirely; we keep a thin fallback
      # for explicit non-assign returns.)
      assigns = collect_assigns
      return success_response(assigns, status) if assigns.any?

      return success_response({}, status) if result.nil?

      success_response(serialize_for_response(result), status)
    end

    def lambda_response?(result)
      result.is_a?(Hash) && (result.key?(:statusCode) || result.key?('statusCode'))
    end

    # Instance variables set during the action (excluding framework internals).
    # Keys are the ivar names without @ — so @posts becomes { posts: ... }.
    def collect_assigns
      before = @__assigns_before || []
      (instance_variables - before - FRAMEWORK_IVARS).each_with_object({}) do |ivar, hash|
        key = ivar.to_s.delete_prefix('@')
        next if key.start_with?('_')

        hash[key.to_sym] = serialize_for_response(instance_variable_get(ivar))
      end
    end

    # Deep-serialize models/relations into JSON-friendly hashes/arrays.
    # ActiveItem::Relation (and any Enumerable of models) maps via to_h on each record.
    def serialize_for_response(value)
      case value
      when nil, String, Numeric, TrueClass, FalseClass
        value
      when Symbol
        value.to_s
      when Hash
        value.each_with_object({}) do |(k, v), h|
          h[k.is_a?(Symbol) ? k : k.to_s] = serialize_for_response(v)
        end
      when Array
        value.map { |v| serialize_for_response(v) }
      else
        serialize_object(value)
      end
    end

    def serialize_object(value)
      # Relations are Enumerable — map each record (don't call Enumerable#to_h)
      if defined?(ActiveItem::Relation) && value.is_a?(ActiveItem::Relation)
        value.map { |record| serialize_for_response(record) }
      elsif value.respond_to?(:to_h) && !value.is_a?(Enumerable)
        serialize_for_response(value.to_h)
      elsif value.is_a?(Enumerable)
        value.map { |item| serialize_for_response(item) }
      elsif value.respond_to?(:to_h)
        serialize_for_response(value.to_h)
      else
        value
      end
    end
  end
end
