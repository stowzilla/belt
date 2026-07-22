# frozen_string_literal: true

require 'yaml'
require 'json'
require_relative 'app_detection'

module Belt
  module CLI
    # Reads config/lambda/*.yml files and produces a merged lambda_config hash
    # suitable for Conveyor Belt's `lambda_config` variable.
    #
    # Each YAML file follows a database.yml-like pattern:
    #
    #   # config/lambda/customer.yml
    #   default: &default
    #     timeout: 60
    #     memory_size: 512
    #     env_keys:
    #       - IMAGES_BUCKET_NAME
    #       - IMAGES_CLOUDFRONT_DOMAIN
    #
    #   dev:
    #     <<: *default
    #     memory_size: 256
    #
    #   prod:
    #     <<: *default
    #     timeout: 30
    #     memory_size: 1024
    #
    class LambdaConfigCommand
      include AppDetection

      SUPPORTED_KEYS = %w[
        timeout memory_size env_vars env_keys
        s3_buckets dynamodb_tables sns_triggers sqs_triggers
        reserved_concurrency ephemeral_storage
      ].freeze

      def self.run(args)
        options = {}

        i = 0
        while i < args.length
          case args[i]
          when '-e', '--environment'
            i += 1
            options[:environment] = args[i]
          when '-f', '--format'
            i += 1
            options[:format] = args[i]
          when '--lambda'
            i += 1
            options[:lambda] = args[i]
          when '-h', '--help'
            puts help_text
            exit 0
          end
          i += 1
        end

        new(options).run
      end

      def self.help_text
        <<~HELP
          Read lambda config from config/lambda/*.yml files.

          Usage: belt lambda-config [options]

          Reads YAML config files and produces a merged configuration hash for the
          specified environment (like database.yml in Rails).

          Options:
            -e, --environment ENV    Target environment (default: dev)
            -f, --format FORMAT      Output format: json (default), terraform
            --lambda NAME            Only output config for a specific lambda
            -h, --help               Show this help

          Examples:
            belt lambda-config -e prod
            belt lambda-config -e dev --format terraform
            belt lambda-config --lambda customer -e prod

          Config files live at config/lambda/<name>.yml. Each file can define
          environment-specific overrides using YAML anchors:

            # config/lambda/customer.yml
            default: &default
              timeout: 60
              memory_size: 512
              env_keys:
                - IMAGES_BUCKET_NAME
                - STRIPE_KEY

            dev:
              <<: *default
              memory_size: 256

            prod:
              <<: *default
              memory_size: 1024

          Keys:
            timeout              Lambda timeout in seconds (default: 30)
            memory_size          Lambda memory in MB (default: 256)
            env_keys             List of env var names this lambda needs
            env_vars             Static env vars (key: value pairs)
            s3_buckets           S3 bucket access declarations
            dynamodb_tables      DynamoDB table access declarations
            sns_triggers         SNS topic triggers
            sqs_triggers         SQS queue triggers
            reserved_concurrency Reserved concurrency limit
            ephemeral_storage    Ephemeral storage in MB (512-10240)
        HELP
      end

      def initialize(options = {})
        @environment = options[:environment] || ENV.fetch('BELT_ENV', 'dev')
        @format = options[:format] || 'json'
        @lambda_filter = options[:lambda]
        @config_dir = 'config/lambda'
      end

      def run
        unless Dir.exist?(@config_dir)
          abort "Error: #{@config_dir}/ not found. Create lambda config files there."
        end

        configs = load_all_configs
        configs = configs.select { |name, _| name == @lambda_filter } if @lambda_filter

        if configs.empty?
          if @lambda_filter
            abort "Error: No config found for lambda '#{@lambda_filter}' in #{@config_dir}/"
          else
            abort "Error: No .yml files found in #{@config_dir}/"
          end
        end

        output(configs)
      end

      # Public API: load and merge all configs for a given environment.
      # Used by other belt commands and potentially by the Conveyor Belt provider.
      def self.load_configs(environment: 'dev', config_dir: 'config/lambda')
        return {} unless Dir.exist?(config_dir)

        configs = {}
        Dir.glob(File.join(config_dir, '*.yml')).sort.each do |file|
          name = File.basename(file, '.yml')
          raw = YAML.safe_load(File.read(file), aliases: true) || {}
          configs[name] = resolve_environment(raw, environment)
        end
        configs
      end

      private

      def load_all_configs
        self.class.load_configs(environment: @environment, config_dir: @config_dir)
      end

      def self.resolve_environment(raw, environment)
        # Merge: default < environment-specific
        base = raw['default'] || {}
        env_config = raw[environment] || {}
        merged = deep_merge(base, env_config)

        # Remove the YAML anchor/environment keys from output
        merged.reject { |k, _| k == 'default' || !SUPPORTED_KEYS.include?(k) }
      end

      def self.deep_merge(base, override)
        base.merge(override) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          else
            new_val
          end
        end
      end

      def output(configs)
        case @format
        when 'json'
          puts JSON.pretty_generate(configs)
        when 'terraform'
          output_terraform(configs)
        else
          abort "Unknown format: #{@format}. Use 'json' or 'terraform'."
        end
      end

      # Output a Terraform-compatible lambda_config block.
      # This can be piped to a .tfvars file or used by the provider directly.
      def output_terraform(configs)
        puts 'lambda_config = {'
        configs.each_with_index do |(name, config), idx|
          puts "  #{name} = {"
          puts "    timeout     = #{config['timeout']}" if config['timeout']
          puts "    memory_size = #{config['memory_size']}" if config['memory_size']
          if config['reserved_concurrency']
            puts "    reserved_concurrency = #{config['reserved_concurrency']}"
          end
          if config['ephemeral_storage']
            puts "    ephemeral_storage = #{config['ephemeral_storage']}"
          end

          output_env_vars_tf(config) if config['env_vars'] || config['env_keys']
          output_s3_buckets_tf(config['s3_buckets']) if config['s3_buckets']
          output_dynamodb_tables_tf(config['dynamodb_tables']) if config['dynamodb_tables']
          output_sns_triggers_tf(config['sns_triggers']) if config['sns_triggers']
          output_sqs_triggers_tf(config['sqs_triggers']) if config['sqs_triggers']

          puts "  }#{idx < configs.size - 1 ? '' : ''}"
          puts '' if idx < configs.size - 1
        end
        puts '}'
      end

      def output_env_vars_tf(config)
        env_vars = config['env_vars'] || {}
        env_keys = config['env_keys'] || []

        # env_keys become placeholder entries that Terraform must fill
        all_vars = env_vars.dup
        env_keys.each { |k| all_vars[k] ||= '' }

        return if all_vars.empty?

        puts ''
        puts '    env_vars = {'
        all_vars.each do |key, value|
          if value.empty?
            puts "      #{key} = var.#{key.downcase}"
          else
            puts "      #{key} = #{value.inspect}"
          end
        end
        puts '    }'
      end

      def output_s3_buckets_tf(buckets)
        return if buckets.nil? || buckets.empty?

        puts ''
        puts '    s3_buckets = ['
        buckets.each do |bucket|
          puts '      {'
          puts "        bucket_arn  = #{bucket['bucket_arn'] || 'TODO'}"
          puts "        permissions = #{bucket['permissions'].inspect}" if bucket['permissions']
          puts '      }'
        end
        puts '    ]'
      end

      def output_dynamodb_tables_tf(tables)
        return if tables.nil? || tables.empty?

        puts ''
        puts '    dynamodb_tables = ['
        tables.each do |table|
          puts '      {'
          puts "        table_arn   = #{table['table_arn'] || 'TODO'}"
          puts "        permissions = #{table['permissions'].inspect}" if table['permissions']
          puts "        index_names = #{table['index_names'].inspect}" if table['index_names']
          puts '      }'
        end
        puts '    ]'
      end

      def output_sns_triggers_tf(triggers)
        return if triggers.nil? || triggers.empty?

        puts ''
        puts '    sns_triggers = ['
        triggers.each do |trigger|
          puts '      {'
          puts "        topic_arn    = #{trigger['topic_arn'] || 'TODO'}"
          puts "        statement_id = #{trigger['statement_id'].inspect}" if trigger['statement_id']
          puts '      }'
        end
        puts '    ]'
      end

      def output_sqs_triggers_tf(triggers)
        return if triggers.nil? || triggers.empty?

        puts ''
        puts '    sqs_triggers = ['
        triggers.each do |trigger|
          puts '      {'
          puts "        queue_arn  = #{trigger['queue_arn'] || 'TODO'}"
          puts "        batch_size = #{trigger['batch_size']}" if trigger['batch_size']
          puts '      }'
        end
        puts '    ]'
      end
    end
  end
end
