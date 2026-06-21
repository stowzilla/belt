# frozen_string_literal: true

require 'json'

module Belt
  module CLI
    class SetupCommand
      SUBCOMMANDS = %w[state].freeze

      def self.run(args)
        subcommand = args.shift

        case subcommand
        when 'state'
          new.create_state_bucket
        else
          puts "Usage: belt setup state"
          puts "\nCreates an S3 bucket for Terraform state with security best practices:"
          puts "  • Versioning enabled"
          puts "  • AES-256 server-side encryption"
          puts "  • Public access fully blocked"
          puts "  • TLS-only bucket policy"
          puts "  • Lifecycle rules (90-day noncurrent expiration)"
          exit 1
        end
      end

      def initialize
        @app_name = detect_app_name
        @bucket_name = "#{@app_name}-terraform-state"
        @region = detect_region
      end

      def create_state_bucket
        unless aws_configured?
          puts "✗ AWS credentials not configured. Set AWS_PROFILE or configure aws sso login."
          exit 1
        end

        puts "Setting up Terraform state bucket: #{@bucket_name} (#{@region})"
        puts ""

        if bucket_exists?
          puts "✓ Bucket '#{@bucket_name}' already exists — skipping creation"
        else
          create_bucket
          puts "  create  s3://#{@bucket_name}"
        end

        enable_versioning
        puts "  enable  versioning"

        enable_encryption
        puts "  enable  AES-256 encryption"

        block_public_access
        puts "  enable  public access block"

        apply_tls_policy
        puts "  enable  TLS-only bucket policy"

        apply_lifecycle
        puts "  enable  lifecycle rules (90-day noncurrent expiration)"

        puts "\n✓ State bucket '#{@bucket_name}' is ready!"
        puts "\n  You can now run: cd infrastructure/<env> && terraform init"
      end

      private

      def aws_configured?
        system("aws sts get-caller-identity > /dev/null 2>&1")
      end

      def bucket_exists?
        system("aws s3api head-bucket --bucket #{@bucket_name} 2>/dev/null")
      end

      def create_bucket
        cmd = "aws s3api create-bucket --bucket #{@bucket_name} --region #{@region}"
        cmd += " --create-bucket-configuration LocationConstraint=#{@region}" unless @region == 'us-east-1'
        run!(cmd)
      end

      def enable_versioning
        run!("aws s3api put-bucket-versioning --bucket #{@bucket_name} " \
             "--versioning-configuration Status=Enabled")
      end

      def enable_encryption
        run!("aws s3api put-bucket-encryption --bucket #{@bucket_name} " \
             "--server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"},\"BucketKeyEnabled\":true}]}'")
      end

      def block_public_access
        run!("aws s3api put-public-access-block --bucket #{@bucket_name} " \
             "--public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true")
      end

      def apply_tls_policy
        policy = {
          Version: '2012-10-17',
          Statement: [{
            Sid: 'DenyInsecureConnections',
            Effect: 'Deny',
            Principal: '*',
            Action: 's3:*',
            Resource: ["arn:aws:s3:::#{@bucket_name}", "arn:aws:s3:::#{@bucket_name}/*"],
            Condition: { Bool: { 'aws:SecureTransport' => 'false' } }
          }]
        }
        run!("aws s3api put-bucket-policy --bucket #{@bucket_name} --policy '#{JSON.generate(policy)}'")
      end

      def apply_lifecycle
        lifecycle = {
          Rules: [{
            ID: 'expire-noncurrent-versions',
            Status: 'Enabled',
            Filter: {},
            NoncurrentVersionExpiration: { NoncurrentDays: 90 },
            AbortIncompleteMultipartUpload: { DaysAfterInitiation: 7 }
          }]
        }
        run!("aws s3api put-bucket-lifecycle-configuration --bucket #{@bucket_name} " \
             "--lifecycle-configuration '#{JSON.generate(lifecycle)}'")
      end

      def run!(cmd)
        unless system(cmd)
          puts "\n✗ Command failed: #{cmd}"
          exit 1
        end
      end

      def detect_app_name
        routes_file = 'infrastructure/routes.tf.rb'
        if File.exist?(routes_file)
          match = File.read(routes_file).match(/namespace :(\w+)/)
          return match[1] if match
        end
        File.basename(Dir.pwd)
      end

      def detect_region
        # Check backend.tf files for region
        Dir.glob('infrastructure/*/backend.tf').each do |f|
          match = File.read(f).match(/region\s*=\s*"([^"]+)"/)
          return match[1] if match
        end
        'us-east-1'
      end
    end
  end
end
