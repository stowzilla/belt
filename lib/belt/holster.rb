# frozen_string_literal: true

module Belt
  class Holster
    class << self
      def inherited(subclass)
        super
        Belt.holsters << subclass
      end

      # Convention: gem root is two levels up from the holster file
      def gem_root
        @gem_root ||= File.expand_path('../..', caller_locations(1, 1).first.path)
      end

      attr_writer :gem_root, :controllers_path, :models_path, :routes_path, :schema_path

      # Defaults follow Belt project structure conventions
      def controllers_path
        @controllers_path || File.join(gem_root, 'lambda', 'controllers')
      end

      def models_path
        @models_path || File.join(gem_root, 'lambda', 'models')
      end

      def routes_path
        @routes_path || File.join(gem_root, 'infrastructure', 'routes.tf.rb')
      end

      def schema_path
        @schema_path || File.join(gem_root, 'infrastructure', 'schema.tf.rb')
      end

      def holster_name
        name&.split('::')&.first&.downcase || 'unknown'
      end
    end
  end

  @holsters = []

  class << self
    attr_reader :holsters
  end
end
