# frozen_string_literal: true

module Belt
  module CLI
    class EnvironmentConfig
      attr_reader :aws_profile, :env_vars, :backup_config

      # Load environment config from infrastructure/<env>/belt.rb
      # Returns an EnvironmentConfig instance (never nil — unconfigured is valid)
      def self.load(env, infra_dir: nil)
        infra_dir ||= 'infrastructure'
        config_file = File.join(infra_dir, env, 'belt.rb')

        config = new
        return config unless File.exist?(config_file)

        evaluator = ConfigEvaluator.new(config)
        evaluator.evaluate(File.read(config_file), config_file)
        config
      end

      def initialize
        @aws_profile = nil
        @env_vars = {}
        @backup_config = BackupConfig.new
      end

      def aws_profile?
        !@aws_profile.nil? && !@aws_profile.empty?
      end

      def env_vars?
        @env_vars.any?
      end

      def backups?
        @backup_config.any?
      end

      # Apply the configured aws_profile and env vars to the current process.
      # Call this before running terraform, aws cli, etc.
      def apply!
        ENV['AWS_PROFILE'] = @aws_profile if aws_profile?
        @env_vars.each { |key, value| ENV[key] = value }
      end

      class ConfigEvaluator
        def initialize(config)
          @config = config
        end

        def evaluate(content, filename)
          config = @config
          sandbox = Module.new
          belt_proxy = Module.new do
            define_singleton_method(:configure) do |&block|
              block.call(ConfigDSL.new(config))
            end
          end
          sandbox.const_set(:Belt, belt_proxy)
          sandbox.module_eval(content, filename)
        end
      end

      class ConfigDSL
        def initialize(config)
          @config = config
        end

        def aws_profile=(profile)
          @config.instance_variable_set(:@aws_profile, profile.to_s)
        end

        def env(&)
          env_dsl = EnvDSL.new(@config)
          env_dsl.instance_eval(&)
        end

        def backups(enabled = nil, &block)
          if enabled == true
            @config.backup_config.instance_variable_set(:@dynamodb_tables, :all)
          elsif block
            backup_dsl = BackupDSL.new(@config.backup_config)
            backup_dsl.instance_eval(&block)
          end
        end
      end

      class EnvDSL
        def initialize(config)
          @config = config
        end

        def set(key, value)
          @config.instance_variable_get(:@env_vars)[key.to_s] = value.to_s
        end
      end

      # DSL for the backups block
      class BackupDSL
        def initialize(backup_config)
          @backup_config = backup_config
        end

        def dynamodb(scope = :all)
          if scope == :all
            @backup_config.instance_variable_set(:@dynamodb_tables, :all)
          else
            tables = Array(scope)
            @backup_config.instance_variable_set(:@dynamodb_tables, tables.map(&:to_s))
          end
        end

        def cognito(*exports)
          @backup_config.instance_variable_set(:@cognito_exports, exports.flatten.map(&:to_sym))
        end

        def s3(*buckets)
          @backup_config.instance_variable_set(:@s3_buckets, buckets.flatten.map(&:to_sym))
        end

        def retention(opts = {})
          current = @backup_config.instance_variable_get(:@retention)
          merged = current.merge(opts.transform_keys(&:to_sym))
          merged.transform_values! { |v| v.respond_to?(:to_i) ? v.to_i : v }
          @backup_config.instance_variable_set(:@retention, merged)
        end
      end
    end
  end
end
