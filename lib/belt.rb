# frozen_string_literal: true

require_relative "belt/version"
require_relative "belt/parameters"
require_relative "belt/observability"
require_relative "belt/lambda_handler"
require_relative "belt/action_router"

module Belt
  class AuthenticationError < StandardError; end
  class RecordNotFound < StandardError; end
  class ActionNotFound < StandardError; end

  @controller_registry = {}

  def self.register_controller(name, klass)
    @controller_registry[name.to_s] = klass
  end

  def self.controller_registry
    @controller_registry
  end
end

require_relative "belt_controller/base"
