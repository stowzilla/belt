# frozen_string_literal: true

require 'optparse'
require_relative 'app_detection'
require_relative 'environment_config'
require_relative 'dynamo_copier'

module Belt
  module CLI
    # `belt db:copy <from-env> <to-env>` — copies DynamoDB table contents from
    # one environment into another on demand (e.g. pulling prod data into dev
    # for realistic seed data).
    #
    # Reuses the same DynamoCopier used by the nested-environment deploy hook,
    # but resolves table prefixes and AWS profiles for two arbitrary
    # environments instead of a parent/child pair. Prod and dev commonly live
    # in separate AWS accounts, so source and destination profiles are
    # resolved independently (from each environment's `belt.rb`, with
    # `--from-profile` / `--to-profile` available to override).
    class DbCopyCommand
      include AppDetection

      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @options = { force: false }
        parse_options(args)
      end

      def run
        unless @from_env && @to_env
          puts usage
          exit 1
        end

        abort "Error: source and destination environment are the same ('#{@from_env}')." if @from_env == @to_env

        app_name = detect_app_name

        from_profile = @options[:from_profile] || EnvironmentConfig.load(@from_env, infra_dir: infra_dir).aws_profile
        to_profile = @options[:to_profile] || EnvironmentConfig.load(@to_env, infra_dir: infra_dir).aws_profile

        puts "belt → copying DynamoDB data: #{@from_env} → #{@to_env}"
        puts "  from profile: #{from_profile || '(current credentials)'}"
        puts "  to profile:   #{to_profile || '(current credentials)'}"
        puts ''

        success = DynamoCopier.new(
          from_prefixes: prefixes_for(app_name, @from_env),
          to_prefixes: prefixes_for(app_name, @to_env),
          from_profile: from_profile,
          to_profile: to_profile,
          force: @options[:force],
          label: "#{@from_env} → #{@to_env}"
        ).run

        abort "\n✗ db:copy finished with errors" unless success

        puts "\n✅ db:copy complete"
      end

      private

      def infra_dir
        'infrastructure'
      end

      def prefixes_for(app_name, env_name)
        raw = "#{app_name}-#{env_name}-"
        sanitized = raw.tr('_', '-').downcase
        [raw, sanitized].uniq
      end

      def parse_options(args)
        OptionParser.new do |opts|
          opts.banner = 'Usage: belt db:copy <from-env> <to-env> [options]'

          opts.on('--force', 'Overwrite destination tables that already have data') do
            @options[:force] = true
          end

          opts.on('--from-profile PROFILE', 'AWS profile to read the source environment with') do |profile|
            @options[:from_profile] = profile
          end

          opts.on('--to-profile PROFILE', 'AWS profile to write the destination environment with') do |profile|
            @options[:to_profile] = profile
          end

          opts.on('-h', '--help', 'Show this help') do
            puts opts
            exit
          end
        end.parse!(args)

        @from_env = args.shift
        @to_env = args.shift
      end

      def usage
        <<~USAGE
          Usage: belt db:copy <from-env> <to-env> [options]

          Copy DynamoDB table contents from one environment into another.
          Matches tables by name suffix after stripping each environment's
          `<app>-<env>-` prefix (e.g. myapp-prod-posts → myapp-dev-posts).

          By default, destination tables that already contain data are
          skipped (safe to re-run). Use --force to overwrite them.

          AWS profiles are resolved from each environment's
          infrastructure/<env>/belt.rb (config.aws_profile), or overridden
          with --from-profile / --to-profile — useful when source and
          destination live in different AWS accounts.

          Options:
            --force                    Overwrite destination tables with existing data
            --from-profile PROFILE     AWS profile for reading the source environment
            --to-profile PROFILE       AWS profile for writing the destination environment
            -h, --help                 Show this help

          Examples:
            belt db:copy prod dev
            belt db:copy prod dev --force
            belt db:copy prod dev01 --from-profile prod-readonly --to-profile dev
        USAGE
      end
    end
  end
end
