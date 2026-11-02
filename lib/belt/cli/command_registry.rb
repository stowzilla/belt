# frozen_string_literal: true

module Belt
  module CLI
    # Discovers top-level CLI commands provided by external gems.
    #
    # Gems register commands by placing a file at:
    #   lib/belt/commands/<name>_command.rb
    #
    # Each command class must:
    #   - Be named <Name>Command (e.g., ConnectCommand)
    #   - Live in the Belt::Commands module
    #   - Implement .run(args)
    #   - Implement .description for help text (optional)
    #   - Implement .standalone? returning true to run outside a Belt project (optional)
    #
    # Example gem structure:
    #   belt-connect/
    #     lib/
    #       belt/
    #         commands/
    #           connect_command.rb
    #
    # The command is then available as:
    #   belt connect ...
    #
    # Underscores in the file name become hyphens in the command name
    # (lib/belt/commands/feature_flags_command.rb → `belt feature-flags`).
    # Built-in commands win on a name clash; see Belt::CLI.plugin_command.
    module CommandRegistry
      COMMAND_PATH = 'lib/belt/commands'

      class << self
        # Returns a hash of { "name" => command_class } for all discovered commands.
        def discovered_commands
          @discovered_commands ||= discover_all
        end

        # Returns just the names of discovered commands.
        def command_names
          discovered_commands.keys
        end

        # Returns the command class for a given name, or nil if not found.
        def find(name)
          discovered_commands[name]
        end

        # Reset cache (useful in tests)
        def reset!
          @discovered_commands = nil
        end

        private

        def discover_all
          commands = {}

          Gem.loaded_specs.each_value do |spec|
            commands_dir = File.join(spec.gem_dir, COMMAND_PATH)
            next unless File.directory?(commands_dir)

            Dir.glob(File.join(commands_dir, '*_command.rb')).each do |file|
              basename = File.basename(file, '.rb').sub(/_command\z/, '')
              klass = load_command_class(file, basename)
              commands[basename.tr('_', '-')] = klass if klass
            end
          end

          commands
        end

        def load_command_class(file, basename)
          require file

          class_name = "#{classify(basename)}Command"
          Belt::Commands.const_get(class_name, false)
        rescue LoadError, NameError => e
          warn "[Belt] Warning: Failed to load command '#{basename}' from #{file}: #{e.message}"
          nil
        end

        def classify(name)
          name.split('_').map(&:capitalize).join
        end
      end
    end
  end

  # Namespace for top-level command classes provided by external gems
  module Commands
  end
end
