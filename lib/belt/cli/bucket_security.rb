# frozen_string_literal: true

module Belt
  module CLI
    module BucketSecurity
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
        puts "  #{audit[:versioning] ? '✓' : '✗'} Versioning"
        puts "  #{audit[:encryption] ? '✓' : '✗'} Encryption (AES-256)"
        puts "  #{audit[:public_access_block] ? '✓' : '✗'} Public access block"
        puts "  #{audit[:tls_policy] ? '✓' : '✗'} TLS-only policy"
      end

      def check_versioning(bucket)
        output = safe_capture('aws', 's3api', 'get-bucket-versioning', '--bucket', bucket, '--output', 'json')
        return false unless output

        data = JSON.parse(output)
        data['Status'] == 'Enabled'
      rescue JSON::ParserError
        false
      end

      def check_encryption(bucket)
        output = safe_capture('aws', 's3api', 'get-bucket-encryption', '--bucket', bucket, '--output', 'json')
        return false unless output

        data = JSON.parse(output)
        rules = data.dig('ServerSideEncryptionConfiguration', 'Rules') || []
        rules.any? { |r| r.dig('ApplyServerSideEncryptionByDefault', 'SSEAlgorithm') }
      rescue JSON::ParserError
        false
      end

      def check_public_access_block(bucket)
        output = safe_capture('aws', 's3api', 'get-public-access-block', '--bucket', bucket, '--output', 'json')
        return false unless output

        data = JSON.parse(output)
        config = data['PublicAccessBlockConfiguration'] || {}
        config['BlockPublicAcls'] && config['IgnorePublicAcls'] &&
          config['BlockPublicPolicy'] && config['RestrictPublicBuckets']
      rescue JSON::ParserError
        false
      end

      def check_tls_policy(bucket)
        output = safe_capture('aws', 's3api', 'get-bucket-policy', '--bucket', bucket, '--output', 'json')
        return false unless output

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

      def harden_bucket(bucket, audit)
        unless audit[:versioning]
          enable_versioning(bucket)
          puts '  enable  versioning'
        end
        unless audit[:encryption]
          enable_encryption(bucket)
          puts '  enable  AES-256 encryption'
        end
        unless audit[:public_access_block]
          block_public_access(bucket)
          puts '  enable  public access block'
        end
        return if audit[:tls_policy]

        apply_tls_policy(bucket)
        puts '  enable  TLS-only bucket policy'
      end

      private

      def enable_versioning(bucket)
        run!('aws', 's3api', 'put-bucket-versioning', '--bucket', bucket,
             '--versioning-configuration', 'Status=Enabled')
      end

      def enable_encryption(bucket)
        config = '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
        run!('aws', 's3api', 'put-bucket-encryption', '--bucket', bucket,
             '--server-side-encryption-configuration', config)
      end

      def block_public_access(bucket)
        run!('aws', 's3api', 'put-public-access-block', '--bucket', bucket,
             '--public-access-block-configuration',
             'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true')
      end

      def apply_tls_policy(bucket)
        policy = {
          Version: '2012-10-17',
          Statement: [{
            Sid: 'DenyInsecureConnections', Effect: 'Deny', Principal: '*', Action: 's3:*',
            Resource: ["arn:aws:s3:::#{bucket}", "arn:aws:s3:::#{bucket}/*"],
            Condition: { Bool: { 'aws:SecureTransport' => 'false' } }
          }]
        }
        run!('aws', 's3api', 'put-bucket-policy', '--bucket', bucket, '--policy', JSON.generate(policy))
      end
    end
  end
end
