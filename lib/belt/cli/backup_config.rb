# frozen_string_literal: true

module Belt
  module CLI
    class BackupConfig
      attr_reader :dynamodb_tables, :cognito_exports, :s3_buckets, :retention

      # Load backup config from infrastructure/<env>/belt.rb
      # Returns nil if no config file exists or backups aren't configured
      def self.load(env, infra_dir: nil)
        infra_dir ||= 'infrastructure'
        config_file = File.join(infra_dir, env, 'belt.rb')
        return nil unless File.exist?(config_file)

        config = new
        evaluator = ConfigEvaluator.new(config)
        evaluator.evaluate(File.read(config_file), config_file)

        # Return nil if no backups were configured
        config.any? ? config : nil
      end

      def initialize
        @dynamodb_tables = nil # nil = not configured, :all = all tables, Array = specific tables
        @cognito_exports = []  # e.g. [:users, :pool_config]
        @s3_buckets = []       # e.g. [:legal_documents]
        @retention = { snapshots: 90, cognito: 10, s3: 10 }
      end

      def dynamodb?
        !@dynamodb_tables.nil?
      end

      def cognito?
        @cognito_exports.any?
      end

      def any?
        dynamodb? || cognito? || @s3_buckets.any?
      end

      # Evaluates the belt.rb config file in an isolated context
      # that intercepts Belt.configure calls
      class ConfigEvaluator
        def initialize(config)
          @config = config
        end

        def evaluate(content, filename)
          # The config file calls Belt.configure { |config| ... }
          # We wrap the content to intercept the Belt constant lookup
          # by evaluating in a module where Belt is redefined
          config = @config
          sandbox = Module.new
          # Define a Belt module inside the sandbox that has .configure
          belt_proxy = Module.new do
            define_singleton_method(:configure) do |&block|
              block.call(ConfigDSL.new(config))
            end
          end
          sandbox.const_set(:Belt, belt_proxy)

          # Evaluate the file content within the sandbox module
          sandbox.module_eval(content, filename)
        end
      end

      # DSL yielded to the block inside Belt.configure { |config| ... }
      class ConfigDSL
        def initialize(config)
          @config = config
        end

        def backups(enabled = nil, &block)
          if enabled == true
            # Simple mode: config.backups = true → just DynamoDB for all tables
            @config.instance_variable_set(:@dynamodb_tables, :all)
          elsif block
            backup_dsl = BackupDSL.new(@config)
            backup_dsl.instance_eval(&block)
          end
        end
      end

      # DSL for the backups block
      class BackupDSL
        def initialize(config)
          @config = config
        end

        def dynamodb(scope = :all)
          if scope == :all
            @config.instance_variable_set(:@dynamodb_tables, :all)
          else
            tables = Array(scope)
            @config.instance_variable_set(:@dynamodb_tables, tables.map(&:to_s))
          end
        end

        def cognito(*exports)
          @config.instance_variable_set(:@cognito_exports, exports.flatten.map(&:to_sym))
        end

        def s3(*buckets)
          @config.instance_variable_set(:@s3_buckets, buckets.flatten.map(&:to_sym))
        end

        def retention(opts = {})
          current = @config.instance_variable_get(:@retention)
          merged = current.merge(opts.transform_keys(&:to_sym))

          # Convert duration objects (90.days) to integer days
          merged.transform_values! do |v|
            v.respond_to?(:to_i) ? v.to_i : v
          end

          @config.instance_variable_set(:@retention, merged)
        end
      end
    end
  end
end
