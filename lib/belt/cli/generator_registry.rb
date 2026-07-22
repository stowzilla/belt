# frozen_string_literal: true

module Belt
  module CLI
    # Discovers and manages generators provided by external gems.
    #
    # Gems register generators by placing a file at:
    #   lib/belt/generators/<name>_generator.rb
    #
    # Each generator class must:
    #   - Be named <Name>Generator (e.g., MessagingGenerator)
    #   - Live in the Belt::Generators module
    #   - Implement .run(args) for generation
    #   - Implement .destroy(args) for teardown (optional)
    #   - Implement .description for help text (optional)
    #
    # Example gem structure:
    #   belt-messaging/
    #     lib/
    #       belt/
    #         generators/
    #           messaging_generator.rb
    #
    # The generator is then available as:
    #   belt generate messaging
    #   belt destroy messaging
    #
    module GeneratorRegistry
      GENERATOR_PATH = 'lib/belt/generators'

      class << self
        # Returns a hash of { "name" => generator_class } for all discovered generators.
        def discovered_generators
          @discovered_generators ||= discover_all
        end

        # Returns just the names of discovered generators.
        def generator_names
          discovered_generators.keys
        end

        # Loads and returns the generator class for a given name.
        # Returns nil if not found.
        def find(name)
          discovered_generators[name]
        end

        # Reset cache (useful in tests)
        def reset!
          @discovered_generators = nil
        end

        private

        def discover_all
          generators = {}

          Gem.loaded_specs.each_value do |spec|
            generators_dir = File.join(spec.gem_dir, GENERATOR_PATH)
            next unless File.directory?(generators_dir)

            Dir.glob(File.join(generators_dir, '*_generator.rb')).each do |file|
              name = File.basename(file, '.rb').sub(/_generator\z/, '')
              klass = load_generator_class(file, name)
              generators[name] = klass if klass
            end
          end

          generators
        end

        def load_generator_class(file, name)
          require file

          class_name = "#{classify(name)}Generator"
          Belt::Generators.const_get(class_name)
        rescue LoadError, NameError => e
          warn "[Belt] Warning: Failed to load generator '#{name}' from #{file}: #{e.message}"
          nil
        end

        def classify(name)
          name.split('_').map(&:capitalize).join
        end
      end
    end
  end

  # Namespace for generator classes provided by external gems
  module Generators
  end
end
