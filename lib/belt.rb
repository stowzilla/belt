# frozen_string_literal: true

require_relative 'belt/version'
require_relative 'belt/parameters'
require_relative 'belt/observability'
require_relative 'belt/lambda_handler'
require_relative 'belt/action_router'

module Belt
  class AuthenticationError < StandardError; end
  class RecordNotFound < StandardError; end
  class ActionNotFound < StandardError; end

  @controller_paths = []
  @gem_controller_paths = []
  @gem_model_paths = []

  class << self
    attr_reader :controller_paths, :gem_controller_paths, :gem_model_paths

    # Register a gem's controller directory so ActionRouter can resolve its controllers
    def register_controllers(path)
      @gem_controller_paths << path unless @gem_controller_paths.include?(path)
    end

    # Register a gem's model directory for autoloading by the host app
    def register_models(path)
      @gem_model_paths << path unless @gem_model_paths.include?(path)
    end

    # All controller paths: app-defined + gem-registered
    def all_controller_paths
      controller_paths + gem_controller_paths.select { |p| File.directory?(p) }
    end

    # All gem model paths that exist on disk
    def all_model_paths
      gem_model_paths.select { |p| File.directory?(p) }
    end
  end
end

require_relative 'belt_controller/base'
