# frozen_string_literal: true

require 'json'

module Belt
  module CLI
    class SetupCommand
      SUBCOMMANDS = %w[state].freeze

      SECURITY_CHECKS = %i[versioning encryption public_access_block tls_policy].freeze

      def self.run(args)
        subcommand = args.shift

        case subcommand
        when 'state'
          new(args).run_state_setup
        else
          puts "Usage: belt setup state [env] [--bucket BUCKET_NAME] [--select]"
          puts "\nSets up an S3 bucket for Terraform state with security best practices."
          puts "\nModes:"
          puts "  belt setup state              # Auto-detect or create shared bucket"
          puts "  belt setup state --select     # List buckets and pick one interactively"
          puts "  belt setup state wups         # Env-specific bucket: <app>-terraform-state-wups"
          puts "  belt setup state --bucket my-bucket  # Use/create a specific bucket"
          puts "\nSecurity enforcement:"
          puts "  • Versioning enabled"
          puts "  • AES-256 server-side encryption"
          puts "  • Public access fully blocked"
          puts "  • TLS-only bucket policy"
          puts "  • Lifecycle rules (90-day noncurrent expiration)"
          puts "\nWill refuse to use buckets that fail security validation."
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
          puts "✗ AWS credentials not configured. Set AWS_PROFILE or configure aws sso login."
          exit 1
        end

        if @select_mode
          @bucket_name = interactive_bucket_selection
        end

        if bucket_exists?(@bucket_name)
          puts "Found existing bucket: #{@bucket_name}"
          audit = audit_bucket_security(@bucket_name)
          print_security_audit(audit)

          if audit.values.all?
            puts "\n✓ Bucket '#{@bucket_name}' passes all security checks"
          else
            puts "\n⚠ Bucket '#{@bucket_name}' has security issues."
            print "\nApply security hardening? [Y/n] "
            response = $stdin.gets&.strip&.downcase
            if response.nil? || response.empty? || response == 'y'
              harden_bucket(@bucket_name, audit)
            else
              puts "✗ Refusing to use insecure bucket. Fix manually or choose a different bucket."
              exit 1
            end
          end
        else
          puts "Creating state bucket: #{@bucket_name} (#{@region})"
          create_bucket(@bucket_name)
          puts "  create  s3://#{@bucket_name}"
          harden_bucket(@bucket_name, {})
        end

        apply_lifecycle(@bucket_name)
        puts "  ensure  lifecycle rules (90-day noncurrent expiration)"

        update_backend_config

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
            abort "✗ --bucket requires a value" unless @custom_bucket
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
          puts "No buckets found. Creating a new one."
          return @bucket_name
        end

        # Show buckets with index
        buckets.each_with_index do |b, i|
          puts "  [#{i + 1}] #{b}"
        end
        puts "  [N] Create new bucket (#{@bucket_name})"
        puts ""
        print "Select bucket [1-#{buckets.size}] or N for new: "
        choice = $stdin.gets&.strip

        if choice.nil? || choice.downcase == 'n' || choice.empty?
          @bucket_name
        else
          idx = choice.to_i - 1
          if idx >= 0 && idx < buckets.size
            buckets[idx]
          else
            puts "✗ Invalid selection"
            exit 1
          end
        end
      end

      def list_buckets
        output = `aws s3api list-buckets --query "Buckets[].Name" --output json 2>/dev/null`
        return [] unless $?.success?

        JSON.parse(output)
      rescue JSON::ParserError
        []
      end

      # --- Security audit ---

      def audit_bucket_security(bucket)
        {
          versioning: check_versioning(bucket),
          encryption: check_encryption(bucket),
          public_access_block: check_public_access_block(bucket),
          tls_policy: check_tls_policy(bucket)
        }
      end

      def print_security_audit(audit)
        puts "\nSecurity audit:"
        puts "  #{icon(audit[:versioning])} Versioning"
        puts "  #{icon(audit[:encryption])} Encryption (AES-256)"
        puts "  #{icon(audit[:public_access_block])} Public access block"
        puts "  #{icon(audit[:tls_policy])} TLS-only policy"
      end

      def icon(passing)
        passing ? '✓' : '✗'
      end

      def check_versioning(bucket)
        output = `aws s3api get-bucket-versioning --bucket #{bucket} --output json 2>/dev/null`
        return false unless $?.success?

        data = JSON.parse(output)
        data['Status'] == 'Enabled'
      rescue JSON::ParserError
        false
      end

      def check_encryption(bucket)
        output = `aws s3api get-bucket-encryption --bucket #{bucket} --output json 2>/dev/null`
        return false unless $?.success?

        data = JSON.parse(output)
        rules = data.dig('ServerSideEncryptionConfiguration', 'Rules') || []
        rules.any? { |r| r.dig('ApplyServerSideEncryptionByDefault', 'SSEAlgorithm') }
      rescue JSON::ParserError
        false
      end

      def check_public_access_block(bucket)
        output = `aws s3api get-public-access-block --bucket #{bucket} --output json 2>/dev/null`
        return false unless $?.success?

        data = JSON.parse(output)
        config = data['PublicAccessBlockConfiguration'] || {}
        config['BlockPublicAcls'] && config['IgnorePublicAcls'] &&
          config['BlockPublicPolicy'] && config['RestrictPublicBuckets']
      rescue JSON::ParserError
        false
      end

      def check_tls_policy(bucket)
        output = `aws s3api get-bucket-policy --bucket #{bucket} --output json 2>/dev/null`
        return false unless $?.success?

        data = JSON.parse(output)
        policy = JSON.parse(data['Policy'])
        statements = policy['Statement'] || []
        statements.any? do |s|
          s['Effect'] == 'Deny' &&
            s.dig('Condition', 'Bool', 'aws:SecureTransport') == 'false'
        end
      rescue JSON::ParserError, TypeError
        false
      end

      # --- Hardening ---

      def harden_bucket(bucket, audit)
        unless audit[:versioning]
          enable_versioning(bucket)
          puts "  enable  versioning"
        end

        unless audit[:encryption]
          enable_encryption(bucket)
          puts "  enable  AES-256 encryption"
        end

        unless audit[:public_access_block]
          block_public_access(bucket)
          puts "  enable  public access block"
        end

        unless audit[:tls_policy]
          apply_tls_policy(bucket)
          puts "  enable  TLS-only bucket policy"
        end
      end

      # --- AWS operations ---

      def aws_configured?
        system("aws sts get-caller-identity > /dev/null 2>&1")
      end

      def bucket_exists?(bucket)
        system("aws s3api head-bucket --bucket #{bucket} 2>/dev/null")
      end

      def create_bucket(bucket)
        cmd = "aws s3api create-bucket --bucket #{bucket} --region #{@region}"
        cmd += " --create-bucket-configuration LocationConstraint=#{@region}" unless @region == 'us-east-1'
        run!(cmd)
      end

      def enable_versioning(bucket)
        run!("aws s3api put-bucket-versioning --bucket #{bucket} " \
             "--versioning-configuration Status=Enabled")
      end

      def enable_encryption(bucket)
        run!("aws s3api put-bucket-encryption --bucket #{bucket} " \
             "--server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"},\"BucketKeyEnabled\":true}]}'")
      end

      def block_public_access(bucket)
        run!("aws s3api put-public-access-block --bucket #{bucket} " \
             "--public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true")
      end

      def apply_tls_policy(bucket)
        policy = {
          Version: '2012-10-17',
          Statement: [{
            Sid: 'DenyInsecureConnections',
            Effect: 'Deny',
            Principal: '*',
            Action: 's3:*',
            Resource: ["arn:aws:s3:::#{bucket}", "arn:aws:s3:::#{bucket}/*"],
            Condition: { Bool: { 'aws:SecureTransport' => 'false' } }
          }]
        }
        run!("aws s3api put-bucket-policy --bucket #{bucket} --policy '#{JSON.generate(policy)}'")
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
        run!("aws s3api put-bucket-lifecycle-configuration --bucket #{bucket} " \
             "--lifecycle-configuration '#{JSON.generate(lifecycle)}'")
      end

      def run!(cmd)
        unless system(cmd)
          puts "\n✗ Command failed: #{cmd}"
          exit 1
        end
      end

      # --- Backend config ---

      def update_backend_config
        env_dir = @env_name ? "infrastructure/#{@env_name}" : nil
        return unless env_dir && Dir.exist?(env_dir)

        backend_file = File.join(env_dir, 'backend.tf')
        return unless File.exist?(backend_file)

        content = File.read(backend_file)
        updated = content.gsub(/bucket\s*=\s*"[^"]+"/, "bucket  = \"#{@bucket_name}\"")
        if updated != content
          File.write(backend_file, updated)
          puts "  update  #{backend_file} → bucket = \"#{@bucket_name}\""
        end
      end

      # --- Detection ---

      def detect_app_name
        routes_file = 'infrastructure/routes.tf.rb'
        if File.exist?(routes_file)
          match = File.read(routes_file).match(/namespace :(\w+)/)
          return match[1] if match
        end
        File.basename(Dir.pwd)
      end

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
