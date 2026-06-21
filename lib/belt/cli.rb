# frozen_string_literal: true

require_relative 'version'
require_relative 'cli/new_command'
require_relative 'cli/generate_command'

module Belt
  module CLI
    COMMANDS = {
      'new' => Belt::CLI::NewCommand,
      'generate' => Belt::CLI::GenerateCommand,
      'g' => Belt::CLI::GenerateCommand,
      '--version' => ->(_args) { puts "Belt #{Belt::VERSION}" },
      '-v' => ->(_args) { puts "Belt #{Belt::VERSION}" }
    }.freeze

    def self.start(args)
      command = args.shift

      if command.nil?
        puts usage
        exit 1
      end

      handler = COMMANDS[command]

      if handler.nil?
        puts "Unknown command: #{command}\n\n#{usage}"
        exit 1
      end

      if handler.is_a?(Proc)
        handler.call(args)
      else
        handler.run(args)
      end
    end

    def self.usage
      <<~USAGE
        Usage: belt <command> [options]

        Commands:
          new <app_name>                              Create a new Belt application
          generate <resource|model|controller> <name> [field:type ...]  Generate components
          --version                                   Show Belt version

        Examples:
          belt new blog
          belt generate resource post title:string content:text status:string
          belt g model comment body:text author:string
      USAGE
    end
  end
end
