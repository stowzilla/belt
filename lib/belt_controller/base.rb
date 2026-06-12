# frozen_string_literal: true

require 'json'
require 'cgi'
require_relative '../belt/parameters'
require_relative '../belt/helpers/response'
require_relative '../belt/helpers/error_logging'
require_relative '../belt/helpers/cors_origin'

module BeltController
  class Base
    include Belt::Helpers::Response

    attr_reader :event, :body

    class << self
      def rescue_handlers
        @rescue_handlers ||= {}
      end

      def rescue_from(*exceptions, with:)
        exceptions.each { |e| rescue_handlers[e] = with }
      end

      def before_actions
        @before_actions ||= []
      end

      def before_action(method_name, only: nil, except: nil)
        before_actions << { method: method_name, only: only&.map(&:to_sym), except: except&.map(&:to_sym) }
      end

      def after_actions
        @after_actions ||= []
      end

      def after_action(method_name, only: nil, except: nil)
        after_actions << { method: method_name, only: only&.map(&:to_sym), except: except&.map(&:to_sym) }
      end

      def skipped_before_actions
        @skipped_before_actions ||= []
      end

      def skip_before_action(method_name, only: nil, except: nil)
        skipped_before_actions << { method: method_name, only: only&.map(&:to_sym), except: except&.map(&:to_sym) }
      end

      def all_before_actions
        if superclass.respond_to?(:all_before_actions)
          superclass.all_before_actions + before_actions
        else
          before_actions
        end
      end

      def all_after_actions
        if superclass.respond_to?(:all_after_actions)
          superclass.all_after_actions + after_actions
        else
          after_actions
        end
      end

      def all_skipped_before_actions
        if superclass.respond_to?(:all_skipped_before_actions)
          superclass.all_skipped_before_actions + skipped_before_actions
        else
          skipped_before_actions
        end
      end

      def all_rescue_handlers
        if superclass.respond_to?(:all_rescue_handlers)
          superclass.all_rescue_handlers.merge(rescue_handlers)
        else
          rescue_handlers
        end
      end
    end

    rescue_from ArgumentError, with: :handle_argument_error
    rescue_from Belt::RecordNotFound, with: :handle_not_found
    rescue_from Belt::AuthenticationError, with: :handle_authentication_error
    rescue_from Belt::ActionNotFound, with: :handle_action_not_found
    rescue_from ActionController::ParameterMissing, with: :handle_parameter_missing
    rescue_from ActionController::UnpermittedParameters, with: :handle_unpermitted_parameters

    rescue_from ActiveItem::RecordNotFound, with: :handle_not_found if defined?(ActiveItem::RecordNotFound)

    rescue_from ActiveModel::ValidationError, with: :handle_validation_error if defined?(ActiveModel::ValidationError)

    def initialize(event:, body:)
      @event = event
      @raw_body = deep_transform_keys_to_snake_case(body || {})
      @params = nil
    end

    def params
      @params ||= build_params
    end

    def body
      @raw_body
    end

    def dispatch(action_name)
      action_sym = action_name.to_sym
      @current_action = action_sym

      unless respond_to?(action_sym)
        raise Belt::ActionNotFound, "The action '#{action_sym}' could not be found for #{self.class.name}"
      end

      run_before_actions(action_sym)
      result = send(action_sym)
      run_after_actions(action_sym)
      result
    rescue StandardError => e
      handle_exception(e)
    end

    def authenticate!
      user_id = event.dig('requestContext', 'authorizer', 'claims', 'sub')
      raise Belt::AuthenticationError, 'Authentication required' unless user_id

      @current_user_id = user_id
    end

    def current_user_id
      @current_user_id ||= event.dig('requestContext', 'authorizer', 'claims', 'sub')
    end

    def user_groups
      @user_groups ||= extract_user_groups
    end

    def admin?
      user_groups.include?('Admin')
    end

    def employee?
      user_groups.include?('Employee')
    end

    def action_name
      @current_action
    end

    private

    def run_before_actions(action_sym)
      self.class.all_before_actions.each do |callback|
        next if callback[:only] && !callback[:only].include?(action_sym)
        next if callback[:except]&.include?(action_sym)
        next if should_skip_callback?(callback[:method], action_sym)

        send(callback[:method])
      end
    end

    def run_after_actions(action_sym)
      self.class.all_after_actions.each do |callback|
        next if callback[:only] && !callback[:only].include?(action_sym)
        next if callback[:except]&.include?(action_sym)

        send(callback[:method])
      end
    end

    def should_skip_callback?(method_name, action_sym)
      self.class.all_skipped_before_actions.any? do |skip|
        next false unless skip[:method] == method_name

        if skip[:only]
          skip[:only].include?(action_sym)
        elsif skip[:except]
          !skip[:except].include?(action_sym)
        else
          true
        end
      end
    end

    def handle_exception(exception, context = {})
      if @current_action
        controller_name = self.class.name.split('::').last.sub('Controller', '').downcase
        context[:action] ||= "#{controller_name}##{@current_action}"
      end
      context[:resource_id] ||= params['id'] if params['id']

      handler = find_rescue_handler(exception.class)
      if handler
        send(handler, exception, context)
      else
        handle_error_and_respond(exception, 'Internal server error', context, 500)
      end
    end

    def find_rescue_handler(exception_class)
      handlers = self.class.all_rescue_handlers
      return handlers[exception_class] if handlers[exception_class]

      exception_class.ancestors.each do |ancestor|
        break if ancestor == Object
        return handlers[ancestor] if handlers[ancestor]
      end
      nil
    end

    def handle_argument_error(exception, _context = {})
      error_response(exception.message, 400)
    end

    def handle_validation_error(exception, _context = {})
      error_response(exception.model.errors.full_messages.join(', '), 400)
    end

    def handle_not_found(exception, _context = {})
      error_response(exception.message.to_s.empty? ? 'Record not found' : exception.message, 404)
    end

    def handle_action_not_found(exception, _context = {})
      error_response(exception.message, 404)
    end

    def handle_authentication_error(exception, _context = {})
      error_response(exception.message.to_s.empty? ? 'Authentication required' : exception.message, 401)
    end

    def handle_parameter_missing(exception, _context = {})
      error_response("Missing required parameter: #{exception.param}", 400)
    end

    def handle_unpermitted_parameters(exception, _context = {})
      error_response("Unpermitted parameters: #{exception.params.join(', ')}", 400)
    end

    def build_params
      path_params = extract_path_params(@event)
      query_params = @event['queryStringParameters'] || {}
      merged = query_params.merge(@raw_body).merge(path_params)
      ActionController::Parameters.new(merged)
    end

    def extract_path_params(event)
      (event['pathParameters'] || {}).transform_keys { |key| key.to_s.gsub(/([A-Z])/, '_\1').downcase.sub(/^_/, '') }
                                     .transform_values { |v| CGI.unescape(v.to_s) }
    end

    def deep_transform_keys_to_snake_case(value)
      case value
      when Hash
        value.transform_keys { |key| key.to_s.gsub(/([A-Z])/, '_\1').downcase.sub(/^_/, '') }
             .transform_values { |v| deep_transform_keys_to_snake_case(v) }
      when Array
        value.map { |item| deep_transform_keys_to_snake_case(item) }
      else
        value
      end
    end

    def extract_user_groups
      groups = event.dig('requestContext', 'authorizer', 'claims', 'cognito:groups')
      return parse_groups(groups) if groups

      []
    end

    def parse_groups(groups)
      return groups if groups.is_a?(Array)
      return [] unless groups.is_a?(String)

      begin
        parsed = JSON.parse(groups)
        return parsed if parsed.is_a?(Array)
      rescue JSON::ParserError
      end
      groups.split(',').map(&:strip)
    end
  end
end
