# frozen_string_literal: true

require_relative 'app_detection'
require_relative 'env_resolver'
require_relative 'environment_config'
require_relative 'frontend_env_map'
require_relative 'frontend_registry'
require_relative 'terraform_command'

module Belt
  module CLI
    # belt frontend env <environment> [--frontend NAME]
    # belt frontend list
    #
    # Smart-merges terraform outputs into <frontend>/.env using the declarative map
    # (<frontend>/env.yml or .belt/frontend_env.yml for the default frontend).
    class FrontendEnvCommand
      include AppDetection

      def self.run(args)
        subcommand = args.shift

        case subcommand
        when 'env'
          run_env(args)
        when 'list', 'ls'
          run_list
        when nil, '-h', '--help', 'help'
          puts usage
          exit(subcommand.nil? ? 1 : 0)
        else
          puts "Unknown frontend subcommand: #{subcommand}\n\n#{usage}"
          exit 1
        end
      end

      def self.run_list
        registry = FrontendRegistry.new
        if registry.empty?
          puts 'No frontends configured.'
          puts 'Run `belt generate frontend react` or add config/frontends.yml.'
          return
        end

        puts 'Frontends:'
        registry.all.each do |fe|
          marker = fe.default? ? '  (default)' : ''
          status = fe.exists? ? '' : '  missing'
          puts "  #{fe.name.ljust(16)} #{fe.path}/#{marker}#{status}"
        end
      end

      def self.run_env(args)
        frontend_name = FrontendRegistry.extract_flag!(args, '--frontend')
        env = EnvResolver.resolve(args)

        if env.nil?
          puts 'Usage: belt frontend env <environment> [--frontend NAME]'
          puts "\nWrites <frontend>/.env from terraform outputs using the env map."
          puts 'You can also set BELT_ENV to skip the environment argument.'
          puts "\nMap file (optional): <frontend>/env.{yml,yaml} or .belt/frontend_env.{yml,yaml}"
          puts 'Default without map: VITE_API_URL ← api_url'
          puts "\nExamples:"
          puts '  belt frontend env dev'
          puts '  belt frontend env dev --frontend ops'
          puts '  BELT_ENV=dev belt frontend env'
          exit 1
        end

        leftover = args.reject { |a| a.start_with?('-') }
        frontend_name ||= leftover.shift

        if frontend_name
          frontend = FrontendRegistry.new.resolve!(frontend_name)
          new(env, frontend: frontend).run
        else
          frontends = FrontendRegistry.new.all
          abort FrontendRegistry.new.empty_message if frontends.empty?

          frontends.each { |fe| new(env, frontend: fe).run }
        end
      end

      def self.usage
        <<~USAGE
          Frontend helpers.

          Usage:
            belt frontend env <environment> [--frontend NAME]
            belt frontend list
            belt frontend --help

          Env map (optional, per frontend):
            <frontend>/env.yml
            .belt/frontend_env.yml   (default `frontend/` only)

          Multiple frontends: config/frontends.yml (see `belt explain frontend`).

          Example map:
            VITE_API_URL: api_url
            VITE_COGNITO_USER_POOL_ID: cognito_user_pool_id
            VITE_COGNITO_CLIENT_ID: cognito_client_id
            VITE_AWS_REGION: cognito_region

          Without a map, belt injects only VITE_API_URL from api_url.

          Smart merge: only keys listed in the map are updated. Other .env keys
          (local secrets, feature flags) are left alone. Missing terraform outputs
          warn and do not overwrite existing values.
        USAGE
      end

      def initialize(env, frontend: nil)
        @env = env
        @app_name = detect_app_name
        @infra_dir = TerraformCommand.find_infrastructure_dir || 'infrastructure'
        @env_dir = File.join(@infra_dir, @env)
        @frontend = frontend || FrontendRegistry.new.resolve!
      end

      def run
        load_and_apply_env_config!

        unless Dir.exist?(@frontend.path)
          abort "Error: No #{@frontend.path}/ directory found. Run `belt generate frontend react` first."
        end

        abort "Error: #{@env_dir} not found. Run `belt generate environment #{@env}` first." unless Dir.exist?(@env_dir)

        map = FrontendEnvMap.new(@env, env_dir: @env_dir, frontend_path: @frontend.path)

        prefix = @frontend.name == 'frontend' ? '' : "[#{@frontend.name}] "
        if map.using_default_map?
          puts "📋 #{prefix}No #{@frontend.path}/env.yml found — using default map (VITE_API_URL ← api_url)"
        else
          puts "📋 #{prefix}Loading env map from #{map.map_path}"
        end

        result = map.write_dotenv!
        updated = result[:updated]

        if updated.empty?
          puts "⚠️  No values written to #{result[:path]} (terraform outputs missing?)"
        else
          puts "✅ Updated #{result[:path]} (#{updated.join(', ')})"
        end
      end

      private

      def load_and_apply_env_config!
        EnvironmentConfig.load(@env, infra_dir: @infra_dir).apply!
      end
    end
  end
end
