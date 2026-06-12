# frozen_string_literal: true

require 'date'
require 'json'

# Rails-like Strong Parameters for Lambda controllers.
# Provides secure parameter filtering without requiring Rails.
module ActionController
  class ParameterMissing < StandardError
    attr_reader :param

    def initialize(param)
      @param = param.to_s
      super("param is missing or the value is empty: #{@param}")
    end
  end

  class UnpermittedParameters < StandardError
    attr_reader :params

    def initialize(params)
      @params = Array(params).map(&:to_s)
      super("found unpermitted parameter(s): #{@params.join(', ')}")
    end
  end

  class Parameters
    def initialize(params = {}, permitted = false)
      @params = normalize_keys(params)
      @permitted = permitted
    end

    def [](key)
      @params[key.to_s]
    end

    def fetch(key, *, &)
      @params.fetch(key.to_s, *, &)
    end

    def key?(key)
      @params.key?(key.to_s)
    end

    def keys
      @params.keys
    end

    def values
      @params.values
    end

    def each(&)
      @params.each(&)
    end

    def empty?
      @params.empty?
    end

    def any?
      @params.any?
    end

    def require(key)
      value = @params[key.to_s]
      raise ParameterMissing, key if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      value.is_a?(Hash) ? Parameters.new(value) : value
    end

    def permit(*filters)
      permitted_params = {}

      filters.each do |filter|
        case filter
        when Symbol, String
          key = filter.to_s
          permitted_params[key] = @params[key] if @params.key?(key)
        when Hash
          filter.each do |key, nested_filter|
            key = key.to_s
            next unless @params.key?(key)

            permitted_params[key] = permit_nested(@params[key], nested_filter)
          end
        end
      end

      Parameters.new(permitted_params, true)
    end

    def permitted?
      @permitted
    end

    def to_h
      raise UnpermittedParameters, @params.keys unless @permitted

      deep_to_h(@params)
    end

    def to_unsafe_h
      deep_to_h(@params)
    end

    def merge(other)
      other_hash = other.is_a?(Parameters) ? other.to_unsafe_h : other
      Parameters.new(@params.merge(normalize_keys(other_hash)), @permitted)
    end

    def slice(*keys)
      Parameters.new(@params.slice(*keys.map(&:to_s)), @permitted)
    end

    def except(*keys)
      Parameters.new(@params.except(*keys.map(&:to_s)), @permitted)
    end

    private

    def normalize_keys(hash)
      return {} unless hash.is_a?(Hash)

      hash.transform_keys { |key| key.to_s.gsub(/([A-Z])/, '_\1').downcase.sub(/^_/, '') }
    end

    def permit_nested(value, filter)
      case value
      when Hash
        if filter == {}
          value
        elsif filter.is_a?(Array)
          Parameters.new(value).permit(*filter).to_unsafe_h
        else
          value
        end
      when Array
        if filter == []
          value.select { |v| scalar?(v) }
        elsif filter.is_a?(Array)
          value.map do |item|
            next item unless item.is_a?(Hash)

            Parameters.new(item).permit(*filter).to_unsafe_h
          end
        else
          value
        end
      else
        value
      end
    end

    def scalar?(value)
      case value
      when String, Symbol, NilClass, Numeric, TrueClass, FalseClass, Date, Time, DateTime
        true
      else
        false
      end
    end

    def deep_to_h(value)
      case value
      when Hash
        value.transform_values { |v| deep_to_h(v) }
      when Array
        value.map { |v| deep_to_h(v) }
      when Parameters
        value.to_unsafe_h
      else
        value
      end
    end
  end
end
