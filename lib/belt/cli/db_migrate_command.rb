# frozen_string_literal: true

require 'optparse'
require 'stringio'
require_relative 'app_detection'
require_relative 'environment_config'
require_relative 'migration_store'
require_relative '../inflector'
require_relative '../migration'

module Belt
  module CLI
    # `belt db:migrate` / `belt db:migrate:status` — data migrations.
    #
    # Each `db/migrate/<timestamp>_<name>.rb` defines a `Belt::Migration`
    # subclass named after the file (`20261030120000_index_usernames.rb` →
    # `IndexUsernames`). Pending ones run oldest-first in the same booted app
    # context `belt console` uses, and each is recorded in SSM (see
    # MigrationStore) only after its `up` returns, so a failure is retried on
    # the next run. `belt deploy` runs this after terraform apply.
    class DbMigrateCommand
      include AppDetection

      MIGRATIONS_DIR = File.join('db', 'migrate')
      FILENAME_PATTERN = /\A(\d+)_([a-z0-9_]+)\.rb\z/

      MigrationFile = Struct.new(:version, :name, :path) do
        def class_name
          Belt::Inflector.camelize(name)
        end

        def label
          name.tr('_', ' ').capitalize
        end
      end

      def self.run(args, status: false)
        new(args, status: status).run
      end

      def self.migrations?(root = Dir.pwd)
        Dir.glob(File.join(root, MIGRATIONS_DIR, '*.rb')).any?
      end

      def initialize(args, status: false)
        @options = { status: status, yes: false }
        parse_options(args)
      end

      def run
        ENV['BUNDLE_GEMFILE'] ||= File.join(Belt.root, 'Gemfile')
        unless File.exist?(ENV['BUNDLE_GEMFILE'])
          abort "Error: No Gemfile found at #{ENV['BUNDLE_GEMFILE']}. Are you in a Belt project?"
        end

        @environment = @env_arg || ENV.fetch('BELT_ENV', nil) || 'dev'
        ENV['ENVIRONMENT'] = @environment
        apply_env_config!

        @store = MigrationStore.new(app_name: detect_app_name, env: @environment)
        @options[:status] ? print_status : migrate
      rescue MigrationStore::Error => e
        abort "Error: #{e.message}"
      end

      private

      def parse_options(args)
        OptionParser.new do |opts|
          opts.banner = if @options[:status]
                          'Usage: belt db:migrate:status [environment]'
                        else
                          'Usage: belt db:migrate [environment] [options]'
                        end

          unless @options[:status]
            opts.on('-y', '--yes', 'Skip the production confirmation prompt') { @options[:yes] = true }
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

      def migrate
        pending = pending_migrations
        if pending.empty?
          puts "belt → no pending migrations for #{@environment}"
          return
        end

        production_guard!
        boot_app

        puts "belt → running #{pending.size} migration(s) against #{@environment}"
        pending.each { |file| run_migration(file) }
        puts "✅ Migrations complete (#{@environment})"
      end

      def run_migration(file)
        puts "  == #{file.version} #{file.label}"
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        instantiate(file).up
        @store.record!(file.version, file.name)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        puts format('  == %<version>s migrated (%<elapsed>.1fs)', version: file.version, elapsed: elapsed)
      rescue MigrationStore::Error
        raise
      rescue StandardError, ScriptError => e
        abort "\n❌ Migration #{file.version} (#{file.name}) failed: #{e.class}: #{e.message}\n" \
              "#{Array(e.backtrace).first(5).join("\n")}\n\n" \
              'Later migrations were not run. Fix it and re-run ' \
              "`belt db:migrate #{@environment}` (migrations must be safe to re-run)."
      end

      def instantiate(file)
        load File.expand_path(file.path)
        klass = Object.const_get(file.class_name) if Object.const_defined?(file.class_name)
        unless klass.is_a?(Class) && klass < Belt::Migration
          raise NameError, "#{file.path} must define `class #{file.class_name} < Belt::Migration`"
        end

        klass.new(version: file.version, name: file.name)
      end

      def print_status
        applied = @store.applied_versions
        files = migration_files

        puts "\nenvironment: #{@environment}\n\n"
        puts ' Status   Migration ID    Migration Name'
        puts '-' * 50
        files.each do |file|
          puts status_line(applied.include?(file.version) ? 'up' : 'down', file.version, file.label)
        end
        (applied - files.map(&:version)).sort.each do |version|
          puts status_line('up', version, '** NO FILE **')
        end
        puts '  (no migrations in db/migrate)' if files.empty? && applied.empty?
      end

      def status_line(state, version, label)
        format('  %<state>-6s  %<version>-14s  %<label>s', state: state, version: version, label: label)
      end

      def pending_migrations
        applied = @store.applied_versions
        migration_files.reject { |file| applied.include?(file.version) }
      end

      def migration_files
        Dir.glob(File.join(MIGRATIONS_DIR, '*.rb')).map do |path|
          match = File.basename(path).match(FILENAME_PATTERN)
          abort "Error: #{path} must be named <timestamp>_<snake_case_name>.rb" unless match

          MigrationFile.new(match[1], match[2], path)
        end.sort_by(&:version)
      end

      def production_guard!
        return unless @environment == 'prod' && !@options[:yes]

        $stdout.write "\n⚠️  WARNING: You are about to migrate PRODUCTION data!\nType 'yes' to continue: "
        response = $stdin.gets&.chomp
        abort "\n❌ Cancelled." unless response&.downcase == 'yes'
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
