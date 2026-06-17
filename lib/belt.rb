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

  class << self
    attr_reader :controller_paths

    # Auto-discover lambda/controllers dirs in all loaded gems
    def gem_controller_paths
      @gem_controller_paths ||= discover_gem_paths('lambda/controllers')
    end

    # Auto-discover lambda/models dirs in all loaded gems
    def gem_model_paths
      @gem_model_paths ||= discover_gem_paths('lambda/models')
    end

    # All controller paths: app-defined + gem-discovered
    def all_controller_paths
      controller_paths + gem_controller_paths
    end

    # All gem model paths that exist on disk
    def all_model_paths
      gem_model_paths
    end

    # Reset cached paths (useful in tests)
    def reset_gem_paths!
      @gem_controller_paths = nil
      @gem_model_paths = nil
    end

    private

    def discover_gem_paths(subdir)
      Gem.loaded_specs.each_value.filter_map do |spec|
        path = File.join(spec.gem_dir, subdir)
        path if File.directory?(path)
      end
    end
  end
end

require_relative 'belt_controller/base'
