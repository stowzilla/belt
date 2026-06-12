# frozen_string_literal: true

require_relative 'belt/version'
require_relative 'belt/parameters'
require_relative 'belt/observability'
require_relative 'belt/lambda_handler'
require_relative 'belt/action_router'
require_relative 'belt/holster'

module Belt
  class AuthenticationError < StandardError; end
  class RecordNotFound < StandardError; end
  class ActionNotFound < StandardError; end

  @controller_paths = []

  class << self
    attr_reader :controller_paths

    # Collects all controller paths: app-defined + holster-provided
    def all_controller_paths
      controller_paths + holsters.select { |h| File.directory?(h.controllers_path) }.map(&:controllers_path)
    end

    # Collects all model paths from holsters
    def all_models_paths
      holsters.select { |h| File.directory?(h.models_path) }.map(&:models_path)
    end

    # Collects all routes files from holsters
    def all_routes_paths
      holsters.select { |h| File.exist?(h.routes_path) }.map(&:routes_path)
    end

    # Collects all schema files from holsters
    def all_schema_paths
      holsters.select { |h| File.exist?(h.schema_path) }.map(&:schema_path)
    end
  end
end

require_relative 'belt_controller/base'
