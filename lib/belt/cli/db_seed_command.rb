# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require_relative 'app_detection'
require_relative 'environment_config'

module Belt
  module CLI
    # `belt db:seed` — Rails-style `rails db:seed` for Belt apps.
    #
    # Loads config/seeds.rb in the same booted app context `belt console`
    # uses (models required, ActiveItem configured), targeting the resolved
    # environment's DynamoDB tables (`<app>-<env>-*`).
    #
    # Refuses to run against an environment that already has data in any of
    # its tables, to avoid silently clobbering a live environment — pass
    # --force to seed anyway (seeds.rb itself is responsible for being
    # idempotent if re-run).
    class DbSeedCommand
      include AppDetection

      SEEDS_FILE = File.join('config', 'seeds.rb')

      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @options = { force: false }
        parse_options(args)
      end

      def run
        ENV['BUNDLE_GEMFILE'] ||= File.join(Belt.root, 'Gemfile')
        unless File.exist?(ENV['BUNDLE_GEMFILE'])
          abort "Error: No Gemfile found at #{ENV['BUNDLE_GEMFILE']}. Are you in a Belt project?"
        end

        unless File.exist?(SEEDS_FILE)
          abort "Error: No #{SEEDS_FILE} found. Create one to define your seed data " \
                '(see `belt explain seeds` for an example).'
        end

        @environment = @env_arg || ENV.fetch('BELT_ENV', nil) || 'dev'
        ENV['ENVIRONMENT'] = @environment

        apply_env_config!
        production_guard!
        guard_against_existing_data! unless @options[:force]

        boot_app

        puts "belt → seeding #{@environment} from #{SEEDS_FILE}"
        load File.expand_path(SEEDS_FILE)
        puts "✅ Seed complete (#{@environment})"
      end

      private

      def parse_options(args)
        OptionParser.new do |opts|
          opts.banner = 'Usage: belt db:seed [environment] [options]'

          opts.on('--force', "Seed even if the environment's tables already have data") do
            @options[:force] = true
          end

          opts.on('-h', '--help', 'Show this help') do
            puts opts
            exit
          end
        end.parse!(args)

        @env_arg = args.shift
      end

      def apply_env_config!
        env_config = EnvironmentConfig.load(@environment)
        env_config.apply!
        puts "  🔑 Using AWS profile: #{env_config.aws_profile}" if env_config.aws_profile?
      end

      def production_guard!
        return unless @environment == 'prod'

        $stdout.write "\n⚠️  WARNING: You are about to seed the PRODUCTION environment!\nType 'yes' to continue: "
        response = $stdin.gets&.chomp
        abort "\n❌ Cancelled." unless response&.downcase == 'yes'
      end

      # Refuses to seed if any table matching this environment's prefix
      # already contains data — avoids clobbering an environment someone
      # already loaded with real (or prior seed) data.
      def guard_against_existing_data!
        app_name = detect_app_name
        prefixes = prefixes_for(app_name, @environment)
        tables = list_tables.select { |name| prefixes.any? { |prefix| name.start_with?(prefix) } }

        non_empty = tables.select { |t| table_has_items?(t) }
        return if non_empty.empty?

        abort "Error: #{@environment} already has data in: #{non_empty.join(', ')}.\n" \
              'Refusing to seed a non-empty environment. Pass --force to seed anyway ' \
              '(seeds.rb is responsible for being idempotent).'
      end

      def prefixes_for(app_name, env_name)
        raw = "#{app_name}-#{env_name}-"
        sanitized = raw.tr('_', '-').downcase
        [raw, sanitized].uniq
      end

      def list_tables
        names = []
        start_name = nil
        loop do
          args = ['dynamodb', 'list-tables', '--output', 'json']
          args += ['--exclusive-start-table-name', start_name] if start_name
          data = aws_json(*args)
          return names if data.nil?

          names.concat(Array(data['TableNames']))
          start_name = data['LastEvaluatedTableName']
          break if start_name.nil? || start_name.empty?
        end
        names
      end

      def table_has_items?(table_name)
        data = aws_json('dynamodb', 'scan', '--table-name', table_name,
                        '--select', 'COUNT', '--limit', '1', '--output', 'json')
        return false if data.nil?

        data.fetch('Count', 0).to_i.positive?
      end

      def aws_json(*)
        output, status = Open3.capture2('aws', *)
        return nil unless status.success?

        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end

      def boot_app
        suppress_warnings { require 'bundler/setup' }

        environment_file = File.join(Belt.root, 'lambda', 'config', 'environment.rb')
        if File.exist?(environment_file)
          load environment_file
        else
          require 'belt'
          load_dir('lib')
          load_dir('models')
        end
      end

      def load_dir(subdir)
        dir = File.join(Belt.root, 'lambda', subdir)
        Dir.glob(File.join(dir, '**', '*.rb')).each { |f| require f } if Dir.exist?(dir)
      end

      def suppress_warnings
        original_verbose = $VERBOSE
        $VERBOSE = nil
        original_stderr = $stderr
        $stderr = StringIO.new
        yield
      ensure
        $stderr = original_stderr
        $VERBOSE = original_verbose
      end
    end
  end
end
