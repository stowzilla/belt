# frozen_string_literal: true

require_relative 'version'
require_relative 'cli/new_command'
require_relative 'cli/generate_command'
require_relative 'cli/setup_command'
require_relative 'cli/terraform_command'

module Belt
  module CLI
    COMMANDS = {
      'new' => Belt::CLI::NewCommand,
      'generate' => Belt::CLI::GenerateCommand,
      'g' => Belt::CLI::GenerateCommand,
      'setup' => Belt::CLI::SetupCommand,
      '--version' => ->(_args) { puts "Belt #{Belt::VERSION}" },
      '-v' => ->(_args) { puts "Belt #{Belt::VERSION}" }
    }.freeze

    TERRAFORM_ACTIONS = Belt::CLI::TerraformCommand::ACTIONS

    def self.start(args)
      command = args.shift

      if command.nil?
        puts usage
        exit 1
      end

      # Terraform shorthand: belt init wups, belt plan wups, belt apply wups
      if TERRAFORM_ACTIONS.include?(command)
        return Belt::CLI::TerraformCommand.run(command, args)
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
          generate <resource|model|controller> <name> Generate components
          setup state                                 Create/select S3 state bucket
          init <env>                                  terraform init for environment
          plan <env>                                  terraform plan for environment
          apply <env>                                 terraform apply for environment
          destroy <env>                               terraform destroy for environment
          output <env>                                terraform output for environment
          --version                                   Show Belt version

        Examples:
          belt new blog
          belt generate resource post title:string content:text status:string
          belt g model comment body:text author:string
          belt setup state
          belt init wups
          belt plan wups
          belt apply wups
      USAGE
    end
  end
end
