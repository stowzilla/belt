# frozen_string_literal: true

require_relative 'version'
require_relative 'root'
require_relative 'cli/env_resolver'
require_relative 'cli/new_command'
require_relative 'cli/generate_command'
require_relative 'cli/destroy_command'
require_relative 'cli/index_command'
require_relative 'cli/frontend_command'
require_relative 'cli/frontend_setup_command'
require_relative 'cli/frontend_deploy_command'
require_relative 'cli/frontend_env_command'
require_relative 'cli/views_command'
require_relative 'cli/setup_command'
require_relative 'cli/terraform_command'
require_relative 'cli/deploy_command'
require_relative 'cli/backup_config'
require_relative 'cli/backup_runner'
require_relative 'cli/server_command'
require_relative 'cli/routes_command'
require_relative 'cli/contracts_command'
require_relative 'cli/lambda_config_command'
require_relative 'cli/tasks_command'
require_relative 'cli/console_command'
require_relative 'cli/logs_command'
require_relative 'cli/doctor_command'
require_relative 'cli/plugin_command'

module Belt
  module CLI
    COMMANDS_DEFINITION = {
      'new' => Belt::CLI::NewCommand,
      %w[generate g] => Belt::CLI::GenerateCommand,
      %w[destroy d] => Belt::CLI::DestroyCommand,
      'routes' => Belt::CLI::RoutesCommand,
      'contracts' => Belt::CLI::ContractsCommand,
      'lambda-config' => Belt::CLI::LambdaConfigCommand,
      %w[console c] => Belt::CLI::ConsoleCommand,
      'logs' => Belt::CLI::LogsCommand,
      %w[tasks --tasks -T] => Belt::CLI::TasksCommand,
      'setup' => Belt::CLI::SetupCommand,
      'doctor' => Belt::CLI::DoctorCommand,
      'plugin' => Belt::CLI::PluginCommand,
      'deploy' => Belt::CLI::DeployCommand,
      'frontend' => Belt::CLI::FrontendEnvCommand,
      %w[server s] => Belt::CLI::ServerCommand,
      %w[version --version -v] => ->(_args) { puts "Belt #{Belt::VERSION}" }
    }.freeze

    COMMANDS = COMMANDS_DEFINITION.each_with_object({}) do |(keys, handler), hash|
      Array(keys).each { |key| hash[key] = handler }
    end.freeze

    TERRAFORM_ACTIONS = Belt::CLI::TerraformCommand::ACTIONS

    # Commands that can run without being inside a Belt project
    STANDALONE_COMMANDS = %w[new version --version -v doctor].freeze

    def self.start(args)
      command = args.shift

      if command.nil?
        puts usage
        exit 1
      end

      # For project-level commands, find and chdir to the project root
      ensure_project_root!(command) unless STANDALONE_COMMANDS.include?(command)

      # `belt destroy` is ambiguous: could be terraform destroy or belt destroy <generator>.
      return if command == 'destroy' && route_destroy_command(args)

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
          contracts [-g PATTERN] [-f json]            Show API request/response contracts
          lambda-config [-e ENV] [-f json|terraform]  Show merged lambda configuration

          console                                     Start an interactive console (IRB)
          c                                           Alias for console
          logs [lambda] [-f] [-s 5m] [-e env]         View Lambda function logs
          tasks [-g PATTERN] [-a]                     List available rake tasks
          -T [-g PATTERN] [-a]                        Alias for tasks
          setup state                                 Create/select S3 state bucket
          setup tables <env>                          Generate DynamoDB tables from schema
          setup frontend <env>                        Generate S3 + CloudFront infrastructure
          doctor                                      Check system dependencies and AWS config
          plugin new <name>                           Scaffold a new Belt plugin gem
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
          belt new blog --frontend react -v   # list every created file
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
          belt plugin new messaging     # scaffold a belt-messaging style plugin gem
      USAGE
    end

    def self.not_in_app_message(command)
      <<~MSG
        Could not find a Belt application. Run `belt #{command}` from within a Belt project directory, or create a new one:

          belt new <app_name>                         Create a new Belt application
          belt new <app_name> --frontend react        With a React frontend
          belt new <app_name> --domain myapp.com      With a custom domain

        Examples:
          belt new blog
          belt new my-api --frontend react
          belt new shop --domain shop.example.com

        See `belt new --help` for all options.
      MSG
    end

    def self.ensure_project_root!(command)
      if Belt.root?
        Dir.chdir(Belt.root)
      else
        puts not_in_app_message(command)
        exit 1
      end
    end

    # Routes `belt destroy` to DestroyCommand when args indicate a generator.
    # Returns true if handled, false to fall through to TerraformCommand.
    def self.route_destroy_command(args) # rubocop:disable Naming/PredicateMethod
      if args.empty? || args.first =~ /\A-/
        if args.include?('--help') || args.include?('-h')
          DestroyCommand.run(args)
          return true
        end
      elsif DestroyCommand::GENERATORS.include?(args.first) || GeneratorRegistry.generator_names.include?(args.first)
        DestroyCommand.run(args)
        return true
      end
      false
    end
  end
end
