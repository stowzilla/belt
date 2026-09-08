# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'environment_config'

module Belt
  module CLI
    # Syncs DNS records for apex (prod) environments to the root zone.
    #
    # Problem: When prod uses the apex domain (example.com), it creates a Route53
    # zone and A records. But the registrar's NS records point to the ROOT zone
    # (infrastructure/dns), not the prod zone. So the prod zone's records are
    # invisible to the internet.
    #
    # Solution: After deploying prod, copy the A alias records (CloudFront, API
    # Gateway) to the root zone, and ensure ACM validation CNAMEs are there too.
    class ApexDnsSync
      DNS_DIR = 'infrastructure/dns'

      def initialize(env, infra_dir:, quiet: false)
        @env = env
        @infra_dir = infra_dir
        @quiet = quiet
        @project_root = find_project_root
        @env_config = EnvironmentConfig.load(env, infra_dir: infra_dir)
        @dns_config = dns_dir_exists? ? load_dns_config : nil
      end

      # Check if this environment needs apex DNS sync.
      # Returns true if:
      # 1. This is a prod environment (app_domain == domain, no env prefix)
      # 2. DNS root zone exists (infrastructure/dns)
      # 3. Domain is configured
      def needs_sync?
        return false unless dns_dir_exists?
        return false unless apex_environment?

        true
      end

      # Run the sync: copy prod's DNS records to the root zone.
      def run
        return unless needs_sync?

        puts '━━━ apex DNS sync ━━━' unless @quiet

        # Get prod's DNS targets (CloudFront, API Gateway)
        targets = fetch_prod_targets
        if targets.empty? || targets[:domain].nil?
          puts '  ⚠ Could not read DNS targets from prod — skipping sync' unless @quiet
          return
        end

        # Get root zone ID
        root_zone_id = fetch_root_zone_id
        unless root_zone_id
          puts '  ⚠ Could not read root zone ID — skipping sync' unless @quiet
          return
        end

        # Sync ACM validation first (cert must validate before CloudFront works)
        sync_acm_validation(root_zone_id, targets[:domain])

        # Sync A alias records
        sync_alias_records(root_zone_id, targets)

        puts '  ✓ Apex DNS synced to root zone' unless @quiet
      end

      private

      def dns_dir_exists?
        dns_path = File.join(@project_root, DNS_DIR)
        Dir.exist?(dns_path) && File.exist?(File.join(dns_path, 'terraform.tfvars'))
      end

      def dns_dir_path
        File.join(@project_root, DNS_DIR)
      end

      def find_project_root
        dir = @infra_dir
        while dir != '/'
          return dir if File.exist?(File.join(dir, 'Gemfile')) ||
                        File.exist?(File.join(dir, 'belt.rb'))

          dir = File.dirname(dir)
        end
        File.dirname(@infra_dir)
      end

      def load_dns_config
        EnvironmentConfig.load('dns', infra_dir: File.join(@project_root, 'infrastructure'))
      rescue StandardError
        nil
      end

      def apex_environment?
        # Check tfvars to see if this is a prod environment
        env_dir = File.join(@infra_dir, @env)
        return false unless Dir.exist?(env_dir)

        tfvars_path = File.join(env_dir, 'terraform.tfvars')
        return false unless File.exist?(tfvars_path)

        content = File.read(tfvars_path)
        domain_match = content.match(/^\s*domain\s*=\s*"([^"]+)"/)
        env_match = content.match(/^\s*environment\s*=\s*"([^"]+)"/)
        parent_match = content.match(/^\s*parent_environment\s*=\s*"([^"]+)"/)

        return false unless domain_match

        # Not apex if it's a nested environment
        parent = parent_match ? parent_match[1] : ''
        return false unless parent.empty?

        # Apex if environment is "prod" (convention)
        env_name = env_match ? env_match[1] : @env
        env_name == 'prod'
      end

      def fetch_prod_targets
        env_dir = File.join(@infra_dir, @env)
        targets = {}

        Dir.chdir(env_dir) do
          env = aws_env_for(@env_config)

          # Get terraform outputs
          output, status = Open3.capture2e(env, 'terraform', 'output', '-json')
          return targets unless status.success?

          data = begin
            JSON.parse(output)
          rescue JSON::ParserError
            {}
          end

          # Extract CloudFront distribution
          cf_domain = data.dig('cloudfront_domain_name', 'value')
          cf_zone = data.dig('cloudfront_hosted_zone_id', 'value')
          if cf_domain
            targets[:cloudfront] = {
              domain_name: cf_domain,
              hosted_zone_id: cf_zone || 'Z2FDTNDATAQYW2' # CloudFront's fixed zone ID
            }
          end

          # Extract API Gateway
          apigw_domain = data.dig('api_gateway_domain_name', 'value')
          apigw_zone = data.dig('api_gateway_hosted_zone_id', 'value')
          if apigw_domain && !apigw_domain.empty? && apigw_zone && !apigw_zone.empty?
            targets[:api_gateway] = {
              domain_name: apigw_domain,
              hosted_zone_id: apigw_zone
            }
          end

          # Read domain from tfvars
          tfvars_path = 'terraform.tfvars'
          if File.exist?(tfvars_path)
            match = File.read(tfvars_path).match(/^\s*domain\s*=\s*"([^"]+)"/)
            targets[:domain] = match[1] if match
          end
        end

        targets
      end

      def fetch_root_zone_id
        return nil unless dns_dir_exists?

        Dir.chdir(dns_dir_path) do
          env = aws_env_for(@dns_config)

          output, status = Open3.capture2e(env, 'terraform', 'output', '-json', 'root_zone_id')
          return nil unless status.success?

          begin
            JSON.parse(output)
          rescue JSON::ParserError
            nil
          end
        end
      end

      def sync_alias_records(root_zone_id, targets)
        return unless targets[:domain] && targets[:cloudfront]

        domain = targets[:domain]
        cf = targets[:cloudfront]
        apigw = targets[:api_gateway]

        # Build change batch for alias records
        changes = []

        # Apex domain → CloudFront
        changes << alias_change('UPSERT', domain, cf[:domain_name], cf[:hosted_zone_id])

        # www → CloudFront
        changes << alias_change('UPSERT', "www.#{domain}", cf[:domain_name], cf[:hosted_zone_id])

        # api → API Gateway (if configured)
        if apigw && apigw[:domain_name] && apigw[:hosted_zone_id]
          changes << alias_change('UPSERT', "api.#{domain}", apigw[:domain_name], apigw[:hosted_zone_id])
        end

        change_batch = {
          Comment: 'Belt apex DNS sync',
          Changes: changes
        }

        # Apply via Route53 API
        env = aws_env_for(@dns_config)
        _, status = Open3.capture2e(
          env,
          'aws', 'route53', 'change-resource-record-sets',
          '--hosted-zone-id', root_zone_id,
          '--change-batch', JSON.generate(change_batch)
        )

        if status.success?
          records = [domain, "www.#{domain}"]
          records << "api.#{domain}" if apigw
          puts "    ✓ A records: #{records.join(', ')}" unless @quiet
        else
          puts '    ⚠ Failed to sync A records to root zone' unless @quiet
        end
      end

      def sync_acm_validation(root_zone_id, domain)
        env_dir = File.join(@infra_dir, @env)

        Dir.chdir(env_dir) do
          env = aws_env_for(@env_config)

          # Get ACM certificate from state
          output, status = Open3.capture2e(
            env,
            'terraform', 'state', 'show', '-json', 'module.app.aws_acm_certificate.app[0]'
          )
          return unless status.success?

          cert_data = begin
            JSON.parse(output)
          rescue JSON::ParserError
            return
          end

          cert_status = cert_data.dig('values', 'status')

          # Skip if already issued
          if cert_status == 'ISSUED'
            puts '    ✓ ACM certificate already issued' unless @quiet
            return
          end

          # Get validation options
          validation_options = cert_data.dig('values', 'domain_validation_options') || []
          return if validation_options.empty?

          # Build CNAME changes
          changes = validation_options.map do |opt|
            {
              Action: 'UPSERT',
              ResourceRecordSet: {
                Name: opt['resource_record_name'],
                Type: 'CNAME',
                TTL: 300,
                ResourceRecords: [{ Value: opt['resource_record_value'] }]
              }
            }
          end

          # Dedupe by name (ACM uses same CNAME for base and wildcard)
          changes.uniq! { |c| c[:ResourceRecordSet][:Name] }

          change_batch = {
            Comment: 'Belt ACM validation sync',
            Changes: changes
          }

          dns_env = aws_env_for(@dns_config)
          _, status = Open3.capture2e(
            dns_env,
            'aws', 'route53', 'change-resource-record-sets',
            '--hosted-zone-id', root_zone_id,
            '--change-batch', JSON.generate(change_batch)
          )

          if status.success?
            puts '    ✓ ACM validation CNAME synced (cert pending)' unless @quiet
          else
            puts '    ⚠ Failed to sync ACM validation CNAME' unless @quiet
          end
        end
      end

      def alias_change(action, name, target_domain, target_zone_id)
        {
          Action: action,
          ResourceRecordSet: {
            Name: name,
            Type: 'A',
            AliasTarget: {
              DNSName: target_domain,
              HostedZoneId: target_zone_id,
              EvaluateTargetHealth: false
            }
          }
        }
      end

      def aws_env_for(config)
        env = {}
        env['AWS_PROFILE'] = config.aws_profile if config&.aws_profile?
        env
      end
    end
  end
end
