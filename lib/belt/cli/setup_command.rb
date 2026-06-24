# frozen_string_literal: true

require 'json'
require 'shellwords'
require 'open3'
require_relative 'app_detection'
require_relative 'bucket_security'
require_relative 'tables_command'
require_relative 'frontend_setup_command'

module Belt
  module CLI
    class SetupCommand
      SUBCOMMANDS = %w[state tables frontend].freeze

      SECURITY_CHECKS = %i[versioning encryption public_access_block tls_policy].freeze

      include AppDetection
      include BucketSecurity

      def self.run(args)
        subcommand = args.shift

        case subcommand
        when 'state'
          new(args).run_state_setup
        when 'tables'
          Belt::CLI::TablesCommand.run(args)
        when 'frontend'
          Belt::CLI::FrontendSetupCommand.run(args)
        else
          puts 'Usage: belt setup <state|tables|frontend> [options]'
          puts "\nSubcommands:"
          puts '  state     Set up S3 bucket for Terraform state'
          puts '  tables    Generate DynamoDB table definitions from schema.tf.rb'
          puts '  frontend  Generate S3 + CloudFront infrastructure for frontend hosting'
          exit 1
        end
      end

      def initialize(args = [])
        @app_name = detect_app_name
        @env_name = nil
        @custom_bucket = nil
        @select_mode = false

        parse_args(args)

        @region = detect_region
        @bucket_name = resolve_bucket_name
      end

      def run_state_setup
        unless aws_configured?
          puts '✗ AWS credentials not configured. Set AWS_PROFILE or configure aws sso login.'
          exit 1
        end

        @bucket_name = interactive_bucket_selection if @select_mode
        setup_or_verify_bucket
        apply_lifecycle(@bucket_name)
        puts '  ensure  lifecycle rules (90-day noncurrent expiration)'
        update_backend_config
        print_success_message
      end

      def setup_or_verify_bucket
        if bucket_exists?(@bucket_name)
          verify_existing_bucket
        else
          create_new_bucket
        end
      end

      def verify_existing_bucket
        puts "Found existing bucket: #{@bucket_name}"
        audit = audit_bucket_security(@bucket_name)
        print_security_audit(audit)

        if audit.values.all?
          puts "\n✓ Bucket '#{@bucket_name}' passes all security checks"
        else
          prompt_and_harden(audit)
        end
      end

      def prompt_and_harden(audit)
        puts "\n⚠ Bucket '#{@bucket_name}' has security issues."
        print "\nApply security hardening? [Y/n] "
        response = $stdin.gets&.strip&.downcase
        if response.nil? || response.empty? || response == 'y'
          harden_bucket(@bucket_name, audit)
        else
          puts '✗ Refusing to use insecure bucket. Fix manually or choose a different bucket.'
          exit 1
        end
      end

      def create_new_bucket
        puts "Creating state bucket: #{@bucket_name} (#{@region})"
        create_bucket(@bucket_name)
        puts "  create  s3://#{@bucket_name}"
        harden_bucket(@bucket_name, {})
      end

      def print_success_message
        puts "\n✓ State bucket '#{@bucket_name}' is ready!"
        if @env_name
          puts "\n  cd infrastructure/#{@env_name} && terraform init"
        else
          puts "\n  cd infrastructure/<env> && terraform init"
        end
      end

      private

      def parse_args(args)
        while (arg = args.shift)
          case arg
          when '--bucket'
            @custom_bucket = args.shift
            abort '✗ --bucket requires a value' unless @custom_bucket
          when '--select'
            @select_mode = true
          when '--help', '-h'
            self.class.run([])
          else
            @env_name = arg unless arg.start_with?('-')
          end
        end
      end

      def resolve_bucket_name
        if @custom_bucket
          @custom_bucket
        elsif @env_name
          "#{@app_name}-terraform-state-#{@env_name}"
        else
          "#{@app_name}-terraform-state"
        end
      end

      # --- Interactive selection ---

      def interactive_bucket_selection
        puts "Listing S3 buckets in account...\n\n"
        buckets = list_buckets
        if buckets.empty?
          puts 'No buckets found. Creating a new one.'
          return @bucket_name
        end

        # Show buckets with index
        buckets.each_with_index do |b, i|
          puts "  [#{i + 1}] #{b}"
        end
        puts "  [N] Create new bucket (#{@bucket_name})"
        puts ''
        print "Select bucket [1-#{buckets.size}] or N for new: "
        choice = $stdin.gets&.strip

        if choice.nil? || choice.downcase == 'n' || choice.empty?
          @bucket_name
        else
          idx = choice.to_i - 1
          if idx >= 0 && idx < buckets.size
            buckets[idx]
          else
            puts '✗ Invalid selection'
            exit 1
          end
        end
      end

      def list_buckets
        output = safe_capture('aws', 's3api', 'list-buckets', '--query', 'Buckets[].Name', '--output', 'json')
        return [] unless output

        JSON.parse(output)
      rescue JSON::ParserError
        []
      end

      # --- AWS operations ---

      def aws_configured?
        system('aws', 'sts', 'get-caller-identity', out: File::NULL, err: File::NULL)
      end

      def bucket_exists?(bucket)
        system('aws', 's3api', 'head-bucket', '--bucket', bucket, err: File::NULL)
      end

      def create_bucket(bucket)
        args = ['aws', 's3api', 'create-bucket', '--bucket', bucket, '--region', @region]
        args.push('--create-bucket-configuration', "LocationConstraint=#{@region}") unless @region == 'us-east-1'
        run!(*args)
      end

      def apply_lifecycle(bucket)
        lifecycle = {
          Rules: [{
            ID: 'expire-noncurrent-versions',
            Status: 'Enabled',
            Filter: {},
            NoncurrentVersionExpiration: { NoncurrentDays: 90 },
            AbortIncompleteMultipartUpload: { DaysAfterInitiation: 7 }
          }]
        }
        run!('aws', 's3api', 'put-bucket-lifecycle-configuration', '--bucket', bucket,
             '--lifecycle-configuration', JSON.generate(lifecycle))
      end

      def run!(*args)
        return if system(*args)

        puts "\n✗ Command failed: #{args.shelljoin}"
        exit 1
      end

      def safe_capture(*)
        output, status = Open3.capture2(*, err: File::NULL)
        status.success? ? output : nil
      end

      # --- Backend config ---

      def update_backend_config
        dirs = if @env_name
                 [File.join('infrastructure', @env_name)]
               else
                 Dir.glob('infrastructure/*/').select { |d| File.exist?(File.join(d, 'backend.tf')) }
               end

        dirs.each do |env_dir|
          next unless Dir.exist?(env_dir)

          backend_file = File.join(env_dir, 'backend.tf')
          next unless File.exist?(backend_file)

          content = File.read(backend_file)
          updated = content.gsub(/bucket\s*=\s*"[^"]+"/, "bucket  = \"#{@bucket_name}\"")
          if updated != content
            File.write(backend_file, updated)
            puts "  update  #{backend_file} → bucket = \"#{@bucket_name}\""
          end
        end
      end

      # --- Detection ---

      def detect_region
        Dir.glob('infrastructure/*/backend.tf').each do |f|
          match = File.read(f).match(/region\s*=\s*"([^"]+)"/)
          return match[1] if match
        end
        'us-east-1'
      end
    end
  end
end
