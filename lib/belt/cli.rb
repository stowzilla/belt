# frozen_string_literal: true

require_relative 'version'
require_relative 'cli/env_resolver'
require_relative 'cli/new_command'
require_relative 'cli/generate_command'
require_relative 'cli/frontend_command'
require_relative 'cli/frontend_setup_command'
require_relative 'cli/frontend_deploy_command'
require_relative 'cli/views_command'
require_relative 'cli/setup_command'
require_relative 'cli/terraform_command'
require_relative 'cli/routes_command'
require_relative 'cli/tasks_command'

module Belt
  module CLI
    COMMANDS_DEFINITION = {
      'new' => Belt::CLI::NewCommand,
      %w[generate g] => Belt::CLI::GenerateCommand,
      'routes' => Belt::CLI::RoutesCommand,
      %w[tasks --tasks -T] => Belt::CLI::TasksCommand,
      'setup' => Belt::CLI::SetupCommand,
      'deploy' => lambda { |args|
        subcommand = args.shift
        if subcommand == 'frontend'
          Belt::CLI::FrontendDeployCommand.run(args)
        else
          puts 'Usage: belt deploy frontend <environment>'
          exit 1
        end
      },
      %w[version --version -v] => ->(_args) { puts "Belt #{Belt::VERSION}" }
    }.freeze

    COMMANDS = COMMANDS_DEFINITION.each_with_object({}) do |(keys, handler), hash|
      Array(keys).each { |key| hash[key] = handler }
    end.freeze

    TERRAFORM_ACTIONS = Belt::CLI::TerraformCommand::ACTIONS

    def self.start(args)
      command = args.shift

      if command.nil?
        puts usage
        exit 1
      end

      # Terraform shorthand: belt init wups, belt plan wups, belt apply wups
      return Belt::CLI::TerraformCommand.run(command, args) if TERRAFORM_ACTIONS.include?(command)

      handler = COMMANDS[command]

      # If no built-in command matched, try running it as a rake task
      if handler.nil?
        return Belt::CLI::TasksCommand.invoke(command, args) if Belt::CLI::TasksCommand.rake_task?(command)

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
          new <app_name> [--frontend react]           Create a new Belt application
          generate <resource|model|controller> <name> Generate components
          generate frontend <react|vue|svelte>        Scaffold a frontend app
          generate views <resource> [fields...]       Generate React pages for REST actions
          generate environment <name>                 Create a new environment
          routes [-g PATTERN] [-f json]               Show route definitions
          tasks [-g PATTERN] [-a]                     List available rake tasks
          -T [-g PATTERN] [-a]                        Alias for tasks
          setup state                                 Create/select S3 state bucket
          setup tables <env>                          Generate DynamoDB tables from schema
          setup frontend <env>                        Generate S3 + CloudFront infrastructure
          deploy frontend <env>                       Build and deploy frontend to AWS
          init <env>                                  terraform init for environment
          plan <env>                                  terraform plan for environment
          apply <env>                                 terraform apply for environment
          destroy <env>                               terraform destroy for environment
          output <env>                                terraform output for environment
          --version                                   Show Belt version

        Rake Tasks:
          Any rake task from your Gemfile dependencies can be run directly:
            belt lambda:build_layer                   Run a rake task by name

        Environment:
          Set BELT_ENV to skip the <env> argument:
            export BELT_ENV=wups
            belt apply                  # uses BELT_ENV
            belt apply dev01            # explicit arg wins

        Examples:
          belt new blog --frontend react
          belt generate resource post title:string content:text status:string
          belt generate frontend react
          belt setup frontend wups
          belt deploy frontend wups
          belt apply wups
          belt tasks                    # list all rake tasks
          belt lambda:build_layer       # run a rake task directly
      USAGE
    end
  end
end
