# frozen_string_literal: true

require_relative 'version'
require_relative 'root'
require_relative 'cli/env_resolver'
require_relative 'cli/new_command'
require_relative 'cli/generate_command'
require_relative 'cli/destroy_command'
require_relative 'cli/frontend_command'
require_relative 'cli/frontend_setup_command'
require_relative 'cli/frontend_deploy_command'
require_relative 'cli/frontend_env_command'
require_relative 'cli/views_command'
require_relative 'cli/setup_command'
require_relative 'cli/terraform_command'
require_relative 'cli/deploy_command'
require_relative 'cli/server_command'
require_relative 'cli/routes_command'
require_relative 'cli/tasks_command'
require_relative 'cli/console_command'

module Belt
  module CLI
    COMMANDS_DEFINITION = {
      'new' => Belt::CLI::NewCommand,
      %w[generate g] => Belt::CLI::GenerateCommand,
      %w[destroy d] => Belt::CLI::DestroyCommand,
      'routes' => Belt::CLI::RoutesCommand,
      %w[console c] => Belt::CLI::ConsoleCommand,
      %w[tasks --tasks -T] => Belt::CLI::TasksCommand,
      'setup' => Belt::CLI::SetupCommand,
      'deploy' => Belt::CLI::DeployCommand,
      'frontend' => Belt::CLI::FrontendEnvCommand,
      %w[server s] => Belt::CLI::ServerCommand,
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

      # `belt destroy` is ambiguous: could be terraform destroy or belt destroy <generator>.
      # Route to DestroyCommand if the first arg is a known generator or help flag.
      if command == 'destroy'
        if args.empty? || args.first =~ /\A-/
          # belt destroy --help → DestroyCommand help
          # belt destroy (no args) → terraform destroy (needs env)
          return DestroyCommand.run(args) if args.include?('--help') || args.include?('-h')
        elsif DestroyCommand::GENERATORS.include?(args.first)
          return DestroyCommand.run(args)
        end
      end

      # Terraform shorthand: belt init wups, belt plan wups, belt apply wups, belt destroy wups
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
          generate <scaffold|model|controller> <name> Generate components
          generate frontend <react|vue|svelte>        Scaffold a frontend app
          generate views <resource> [fields...]       Generate React pages for REST actions
          generate environment <name>                 Create a new environment
          destroy <scaffold|model|controller> <name>  Remove generated components
          destroy frontend                            Remove the frontend/ directory
          destroy views <resource>                    Remove React pages for a resource
          destroy environment <name>                  Remove an environment directory
          server                                      Start local dev server (frontend)
          s                                           Alias for server
          deploy [environment]                        Deploy to AWS (init → plan → apply)
          deploy frontend <env>                       Build and deploy frontend to AWS
          frontend env <env>                          Write frontend/.env from terraform outputs
          routes [-g PATTERN] [-f json]               Show route definitions

          console                                     Start an interactive console (IRB)
          c                                           Alias for console
          tasks [-g PATTERN] [-a]                     List available rake tasks
          -T [-g PATTERN] [-a]                        Alias for tasks
          setup state                                 Create/select S3 state bucket
          setup tables <env>                          Generate DynamoDB tables from schema
          setup frontend <env>                        Generate S3 + CloudFront infrastructure
          init [environment] <env>                    terraform init for environment
          plan [environment] <env>                    terraform plan for environment
          apply [environment] <env>                   terraform apply for environment
          destroy [environment] <env>                 terraform destroy for environment
          output [environment] <env>                  terraform output for environment
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
          belt generate scaffold post title:string content:text status:string
          belt destroy scaffold post
          belt generate frontend react
          belt server                   # Start local frontend server
          belt deploy                   # Deploy dev to AWS
          belt deploy prod --auto       # Deploy prod without confirmation
          belt deploy frontend wups
          belt frontend env wups        # Smart-merge TF outputs into frontend/.env
          belt setup frontend wups
          belt apply wups
          belt tasks                    # list all rake tasks
          belt lambda:build_layer       # run a rake task directly
      USAGE
    end
  end
end
