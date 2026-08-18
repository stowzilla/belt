# frozen_string_literal: true

require_relative 'app_detection'
require_relative 'env_resolver'
require_relative 'frontend_env_map'

module Belt
  module CLI
    # belt frontend env <environment>
    #
    # Smart-merges terraform outputs into frontend/.env using the declarative map
    # (frontend/env.yml or .belt/frontend_env.yml). Only mapped keys are written;
    # custom local keys are preserved.
    class FrontendEnvCommand
      include AppDetection

      def self.run(args)
        subcommand = args.shift

        case subcommand
        when 'env'
          run_env(args)
        when nil, '-h', '--help', 'help'
          puts usage
          exit(subcommand.nil? ? 1 : 0)
        else
          puts "Unknown frontend subcommand: #{subcommand}\n\n#{usage}"
          exit 1
        end
      end

      def self.run_env(args)
        env = EnvResolver.resolve(args)

        if env.nil?
          puts 'Usage: belt frontend env <environment>'
          puts "\nWrites frontend/.env from terraform outputs using the env map."
          puts 'You can also set BELT_ENV to skip the environment argument.'
          puts "\nMap file (optional): frontend/env.{yml,yaml} or .belt/frontend_env.{yml,yaml}"
          puts 'Default without map: VITE_API_URL ← api_url'
          puts "\nExamples:"
          puts '  belt frontend env dev'
          puts '  BELT_ENV=dev belt frontend env'
          exit 1
        end

        new(env).run
      end

      def self.usage
        <<~USAGE
          Frontend helpers.

          Usage:
            belt frontend env <environment>   Write frontend/.env from terraform outputs
            belt frontend --help

          Env map (optional):
            frontend/env.yml
            .belt/frontend_env.yml

          Example map:
            VITE_API_URL: api_url
            VITE_COGNITO_USER_POOL_ID: cognito_user_pool_id
            VITE_COGNITO_CLIENT_ID: cognito_user_pool_client_id
            VITE_AWS_REGION: cognito_region

          Without a map, belt injects only VITE_API_URL from api_url.

          Smart merge: only keys listed in the map are updated. Other .env keys
          (local secrets, feature flags) are left alone. Missing terraform outputs
          warn and do not overwrite existing values.
        USAGE
      end

      def initialize(env)
        @env = env
        @app_name = detect_app_name
        @env_dir = "infrastructure/#{@env}"
      end

      def run
        unless Dir.exist?('frontend')
          abort 'Error: No frontend/ directory found. Run `belt generate frontend react` first.'
        end

        unless Dir.exist?(@env_dir)
          abort "Error: infrastructure/#{@env} not found. Run `belt generate environment #{@env}` first."
        end

        map = FrontendEnvMap.new(@env, env_dir: @env_dir)

        if map.using_default_map?
          puts '📋 No frontend/env.yml found — using default map (VITE_API_URL ← api_url)'
        else
          puts "📋 Loading env map from #{map.map_path}"
        end

        result = map.write_dotenv!
        updated = result[:updated]

        if updated.empty?
          puts "⚠️  No values written to #{result[:path]} (terraform outputs missing?)"
        else
          puts "✅ Updated #{result[:path]} (#{updated.join(', ')})"
        end
      end
    end
  end
end
