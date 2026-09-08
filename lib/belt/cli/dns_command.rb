# frozen_string_literal: true

require 'fileutils'
require 'erb'
require 'json'
require_relative 'app_detection'
require_relative 'environment_config'
require_relative 'setup_command'

module Belt
  module CLI
    class DnsCommand
      TEMPLATE_DIR = File.expand_path('../../templates/dns', __dir__)
      DNS_DIR = 'infrastructure/dns'

      include AppDetection

      def self.run(args)
        subcommand = args.shift

        case subcommand
        when 'deploy', nil
          new.deploy(args)
        when 'generate', 'init'
          new.generate(args)
        when 'add'
          new.add_environment(args)
        when 'remove', 'rm'
          new.remove_environment(args)
        when 'show', 'list'
          new.show(args)
        when 'doctor'
          new.doctor(args)
        when 'sync-validation'
          new.sync_validation(args)
        when '--help', '-h', 'help'
          puts help
        else
          puts "Unknown dns subcommand: #{subcommand}\n\n#{help}"
          exit 1
        end
      end

      def self.help
        <<~HELP
          Usage: belt dns <subcommand>

          Subcommands:
            deploy              Deploy the dns infrastructure (init → plan → apply)
            generate            Create the infrastructure/dns directory (same as belt generate dns)
            add <env>           Add an environment's NS records to dns/terraform.tfvars
            remove <env>        Remove an environment's NS records from dns/terraform.tfvars
            show                Show root zone name servers (for registrar configuration)
            doctor              Diagnose DNS configuration for all environments
            sync-validation     Sync ACM validation CNAMEs to root zone (for apex domains)
            help                Show this help

          Options for generate:
            --aws-profile NAME  AWS profile to use for DNS infrastructure
                               Sets belt.rb config and derives state bucket from account ID

          Options for doctor:
            --env ENV           Check a specific environment only

          Examples:
            belt dns deploy                 # Deploy the root zone
            belt dns generate               # Scaffold infrastructure/dns (prompts for profile)
            belt dns generate --aws-profile fpshared  # Non-interactive with profile
            belt dns add staging            # Add staging's NS records to tfvars
            belt dns remove staging         # Remove staging's NS delegation
            belt dns show                   # Show root name servers to configure at registrar
            belt dns doctor                 # Check DNS health for all environments
            belt dns doctor --env prod      # Check DNS health for prod only

          The dns directory manages your root domain and delegates subdomains to
          per-environment hosted zones. Each environment (dev, staging, prod) gets
          its own Route 53 zone, and this root zone delegates to each of them.

          Workflow:
            1. belt deploy dev              # Deploy environments first
            2. belt dns generate            # Create infrastructure/dns
            3. belt dns add dev             # Add dev's NS records
            4. belt dns deploy              # Deploy root zone
            5. Update registrar NS records to output values

          When destroying an environment:
            1. belt destroy environment dev # Destroy the environment
            2. belt dns remove dev          # Remove DNS delegation
            3. belt dns deploy              # Apply the change

          Special handling for prod (apex domain):
            Prod environments use the apex domain (e.g., example.com, not prod.example.com).
            ACM certificates for apex domains need validation CNAMEs in the root zone.
            `belt deploy prod` handles this automatically when infrastructure/dns exists.
        HELP
      end

      def initialize(quiet: false, aws_profile: nil)
        @app_name = detect_app_name
        @quiet = quiet
        @aws_profile = aws_profile
        @state_bucket = nil # Resolved during generate with profile context
      end

      # --- Doctor ---
      def doctor(args = [])
        require 'open3'

        # Parse --env flag
        env_filter = nil
        env_index = args.index('--env')
        if env_index
          env_filter = args[env_index + 1]
          args.delete_at(env_index + 1)
          args.delete_at(env_index)
        end

        # Load DNS config for shared account credentials
        dns_config = load_dns_config_if_exists

        # Read domain from tfvars
        domain = read_domain_from_tfvars
        unless domain
          puts 'No domain configured.'
          puts "\nSet up DNS first:"
          puts '  belt dns generate'
          exit 1
        end

        puts "DNS Health: #{domain}"
        puts '═' * 60
        puts ''

        # Check root zone
        root_zone_ok = check_root_zone(domain, dns_config)
        puts ''

        # Get list of environments to check
        environments = discover_environments(env_filter)
        if environments.empty?
          puts 'No environments found to check.'
          puts "\nDeploy an environment first:"
          puts '  belt deploy dev'
          return
        end

        # Check each environment
        all_ok = root_zone_ok
        environments.each do |env_name|
          env_ok = check_environment(env_name, domain, dns_config)
          all_ok &&= env_ok
          puts ''
        end

        # Summary
        puts '═' * 60
        if all_ok
          puts '✓ All DNS checks passed'
        else
          puts '⚠ Some DNS issues detected — see details above'
        end
      end

      # --- Sync Validation ---
      # Syncs ACM validation CNAMEs from an environment to the root zone.
      # Primarily used for prod (apex domain) where the env's zone isn't authoritative.
      def sync_validation(args = [])
        require 'open3'

        env_name = args.shift
        if env_name.nil? || env_name.start_with?('-')
          puts 'Usage: belt dns sync-validation <env>'
          puts "\nThis syncs ACM certificate validation CNAMEs from the environment's"
          puts "zone to the root zone. Needed when the environment uses the apex domain"
          puts "(e.g., prod → example.com) because ACM validates against the authoritative"
          puts "zone, which is the root zone, not the environment's zone."
          puts "\nExample:"
          puts '  belt dns sync-validation prod'
          exit 1
        end

        unless Dir.exist?(DNS_DIR)
          puts 'No infrastructure/dns directory found.'
          puts "\nCreate it first:"
          puts '  belt dns generate'
          exit 1
        end

        env_dir = "infrastructure/#{env_name}"
        unless Dir.exist?(env_dir)
          puts "Environment #{env_name} not found at #{env_dir}/"
          exit 1
        end

        sync_acm_validation_to_root_zone!(env_name)
      end

      # Public API for deploy_command to call
      def self.sync_acm_validation_if_needed(env_name)
        # Only sync if DNS is configured
        return unless Dir.exist?(DNS_DIR)

        cmd = new(quiet: true)
        cmd.sync_acm_validation_to_root_zone!(env_name)
      end

      # Core logic: sync ACM validation CNAMEs to root zone
      def sync_acm_validation_to_root_zone!(env_name)
        require 'open3'

        env_config = EnvironmentConfig.load(env_name)
        dns_config = load_dns_config_if_exists

        # Get domain from tfvars
        domain = read_domain_from_tfvars
        return unless domain

        # Determine if this is an apex environment
        is_apex = apex_environment?(env_name, domain)
        unless is_apex
          puts "  ℹ #{env_name} uses subdomain (#{env_name}.#{domain}) — no root zone sync needed" unless @quiet
          return
        end

        puts "  🔄 Syncing ACM validation for #{env_name} (apex domain) to root zone..." unless @quiet

        # Get pending ACM validation records from the environment
        validation_records = fetch_pending_acm_validation(env_name, env_config)
        if validation_records.nil? || validation_records.empty?
          puts '     No pending ACM validation records found' unless @quiet
          return
        end

        # Get root zone ID
        root_zone_id = fetch_root_zone_id(dns_config)
        unless root_zone_id
          puts '     ⚠ Could not find root zone ID — run `belt dns deploy` first' unless @quiet
          return
        end

        # Create/update the validation CNAMEs in the root zone
        validation_records.each do |record|
          create_validation_cname_in_root_zone(root_zone_id, record, dns_config)
        end

        puts '     ✓ ACM validation CNAMEs synced to root zone' unless @quiet
      end

      # --- Generate ---
      def generate(args = [])
        # Parse --aws-profile flag
        profile_index = args.index('--aws-profile')
        if profile_index
          @aws_profile = args[profile_index + 1]
          args.delete_at(profile_index + 1)
          args.delete_at(profile_index)
        end

        if Dir.exist?(DNS_DIR)
          puts "dns infrastructure already exists at #{DNS_DIR}/"
          puts "\nTo configure it:"
          puts "  1. Edit #{DNS_DIR}/terraform.tfvars with your domain and environment NS records"
          puts '  2. Run: belt dns deploy'
          exit 1
        end

        # Prompt for AWS profile if not provided and not quiet mode
        if @aws_profile.nil? && !@quiet && $stdin.tty?
          print 'AWS profile for DNS infrastructure (leave blank to use current credentials): '
          input = $stdin.gets&.strip
          @aws_profile = input unless input.nil? || input.empty?
        end

        # Resolve state bucket using the specified profile (or current credentials)
        @state_bucket = resolve_state_bucket_for_profile(@aws_profile)

        # Ensure the state bucket exists (convention over configuration)
        ensure_state_bucket_exists(@state_bucket)

        puts 'Creating dns infrastructure...' unless @quiet
        if @aws_profile && !@quiet
          puts "  Using AWS profile: #{@aws_profile}"
          puts "  State bucket: #{@state_bucket}"
        end
        FileUtils.mkdir_p(DNS_DIR)

        templates.each do |template_name, dest_file|
          dest_path = File.join(DNS_DIR, dest_file)
          write_template(template_name, dest_path)
          puts "  create  #{dest_path}" unless @quiet
        end

        return if @quiet

        puts "\n✓ dns infrastructure created!"
        puts "\nThis manages your root domain and delegates subdomains to per-environment zones."
        puts "\nNext steps:"
        puts '  1. Deploy your environments first (if not already deployed):'
        puts '       belt deploy dev'
        puts '       belt deploy staging'
        puts ''
        puts '  2. Add each environment\'s NS records:'
        puts '       belt dns add dev'
        puts '       belt dns add staging'
        puts ''
        puts '  3. Deploy the dns infrastructure:'
        puts '       belt dns deploy'
        puts ''
        puts '  4. Update your registrar\'s NS records to the root_name_servers output'
      end

      # --- Deploy ---
      def deploy(args)
        unless Dir.exist?(DNS_DIR)
          puts 'No infrastructure/dns directory found.'
          puts "\nCreate it first:"
          puts '  belt dns generate'
          exit 1
        end

        auto = args.include?('--auto') || args.include?('-y')
        env_config = load_dns_config

        Dir.chdir(DNS_DIR) do
          run_terraform('init', env_config)
          run_terraform('plan', env_config, '-out=tfplan')

          if auto
            run_terraform('apply', env_config, 'tfplan')
            cleanup_plan
          else
            print "\nApply this plan? [y/N] "
            answer = $stdin.gets&.strip&.downcase
            if %w[y yes].include?(answer)
              run_terraform('apply', env_config, 'tfplan')
              cleanup_plan
            else
              cleanup_plan
              puts 'Aborted.'
              exit 1
            end
          end
        end
      end

      def cleanup_plan
        FileUtils.rm_f('tfplan')
      end

      # --- Add Environment ---
      def add_environment(args)
        env_name = args.shift

        if env_name.nil? || env_name.start_with?('-')
          puts 'Usage: belt dns add <env>'
          puts "\nExample: belt dns add staging"
          exit 1
        end

        env_dir = "infrastructure/#{env_name}"
        unless Dir.exist?(env_dir)
          puts "Environment #{env_name} not found at #{env_dir}/"
          exit 1
        end

        # Get NS records from environment
        ns_records = fetch_ns_records(env_name)
        if ns_records.nil? || ns_records.empty?
          puts "Could not fetch NS records for #{env_name}."
          puts "\nMake sure the environment is deployed:"
          puts "  belt deploy #{env_name}"
          exit 1
        end

        # Update terraform.tfvars
        tfvars_path = "#{DNS_DIR}/terraform.tfvars"
        unless File.exist?(tfvars_path)
          puts "#{tfvars_path} not found. Run 'belt dns generate' first."
          exit 1
        end

        update_tfvars(tfvars_path, env_name, ns_records)
        puts "✓ Added #{env_name} NS records to #{tfvars_path}"
        puts "\nRun 'belt dns deploy' to apply the changes."
      end

      # --- Remove Environment ---
      def remove_environment(args)
        env_name = args.shift

        if env_name.nil? || env_name.start_with?('-')
          puts 'Usage: belt dns remove <env>'
          puts "\nExample: belt dns remove staging"
          exit 1
        end

        tfvars_path = "#{DNS_DIR}/terraform.tfvars"
        unless File.exist?(tfvars_path)
          puts "#{tfvars_path} not found."
          puts "\nNo DNS infrastructure to modify."
          exit 1
        end

        content = File.read(tfvars_path)

        # Check if the environment exists in the tfvars
        unless content.include?("#{env_name} =")
          puts "Environment '#{env_name}' not found in #{tfvars_path}."
          puts "\nNothing to remove."
          exit 0
        end

        remove_env_from_tfvars(tfvars_path, env_name)
        puts "✓ Removed #{env_name} NS records from #{tfvars_path}"
        puts "\nRun 'belt dns deploy' to apply the changes."
      end

      # --- Show ---
      def show(_args)
        require 'open3'

        unless Dir.exist?(DNS_DIR)
          puts 'No infrastructure/dns directory found.'
          puts "\nCreate it first:"
          puts '  belt dns generate'
          exit 1
        end

        env_config = load_dns_config
        env = {}
        env['AWS_PROFILE'] = env_config.aws_profile if env_config.aws_profile?

        # Get all outputs in one call
        outputs = Dir.chdir(DNS_DIR) do
          output, status = Open3.capture2e(env, 'terraform', 'output', '-json')
          unless status.success?
            puts 'Failed to read terraform outputs.'
            puts "\nMake sure DNS is deployed:"
            puts '  belt dns deploy'
            exit 1
          end

          begin
            JSON.parse(output)
          rescue JSON::ParserError
            puts 'Failed to parse terraform outputs.'
            exit 1
          end
        end

        # Extract values from terraform state
        name_servers = outputs.dig('root_name_servers', 'value') || []
        zone_id = outputs.dig('root_zone_id', 'value')
        environments = outputs.dig('delegated_environments', 'value') || []

        # Read domain from tfvars
        tfvars_path = "#{DNS_DIR}/terraform.tfvars"
        domain = nil
        if File.exist?(tfvars_path)
          content = File.read(tfvars_path)
          match = content.match(/domain\s*=\s*"([^"]+)"/)
          domain = match[1] if match
        end

        # Verify the zone actually exists in AWS (terraform state can be stale)
        if zone_id && !zone_exists_in_aws?(zone_id, env)
          puts 'Root Zone Not Found'
          puts '==================='
          puts ''
          puts "Terraform state references zone #{zone_id}, but it doesn't exist in AWS."
          puts 'The zone may have been deleted or the state is stale.'
          puts ''
          puts 'To create the root zone:'
          puts '  belt dns deploy'
          exit 1
        end

        if name_servers.empty?
          puts 'No name servers found. Is the DNS zone deployed?'
          puts "\nRun:"
          puts '  belt dns deploy'
          exit 1
        end

        # Display
        puts 'Root Zone Name Servers'
        puts '======================'
        puts ''
        puts "Domain: #{domain}" if domain
        puts "Zone ID: #{zone_id}" if zone_id
        puts ''
        puts 'Configure these at your domain registrar:'
        puts ''
        name_servers.each { |ns| puts "  #{ns}" }
        puts ''

        if environments.any?
          puts "Delegated environments: #{environments.join(', ')}"
        else
          puts 'No environments delegated yet.'
          puts "\nTo add an environment:"
          puts '  belt dns add <env>'
        end
      end

      private

      # ═══════════════════════════════════════════════════════════════════════════
      # Doctor helpers
      # ═══════════════════════════════════════════════════════════════════════════

      def check_root_zone(domain, dns_config)
        require 'open3'

        puts 'Root Zone (shared account)'
        puts '-' * 40

        env = {}
        env['AWS_PROFILE'] = dns_config.aws_profile if dns_config&.aws_profile?

        # Check if root zone exists
        zone_id = fetch_root_zone_id(dns_config)
        if zone_id
          puts "  ✓ Zone ID: #{zone_id}"
        else
          puts '  ✗ Root zone not found'
          puts "    Run: belt dns deploy"
          return false
        end

        # Get NS records from root zone
        ns_output, ns_status = Open3.capture2e(
          env,
          'aws', 'route53', 'list-resource-record-sets',
          '--hosted-zone-id', zone_id,
          '--query', "ResourceRecordSets[?Type=='NS' && Name=='#{domain}.'].ResourceRecords[].Value",
          '--output', 'json'
        )

        if ns_status.success?
          ns_records = begin
            JSON.parse(ns_output)
          rescue StandardError
            []
          end
          if ns_records.any?
            puts "  ✓ NS records configured (#{ns_records.size} servers)"
          else
            puts '  ⚠ No NS records found'
          end
        end

        # Check delegated environments
        delegated = fetch_delegated_environments(dns_config)
        if delegated.any?
          puts "  ✓ Delegated: #{delegated.join(', ')}"
        else
          puts '  ⚠ No environments delegated yet'
          puts "    Run: belt dns add <env>"
        end

        true
      end

      def check_environment(env_name, domain, dns_config)
        require 'open3'

        env_config = EnvironmentConfig.load(env_name)
        env = {}
        env['AWS_PROFILE'] = env_config.aws_profile if env_config.aws_profile?

        is_apex = apex_environment?(env_name, domain)
        env_domain = is_apex ? domain : "#{env_name}.#{domain}"

        puts "#{env_name} (#{env_domain})#{is_apex ? ' [apex]' : ''}"
        puts '-' * 40

        all_ok = true

        # Check zone exists
        zone_id = fetch_env_zone_id(env_name, env_config)
        if zone_id
          puts "  ✓ Zone ID: #{zone_id}"
        else
          puts '  ✗ Hosted zone not found'
          puts "    Run: belt deploy #{env_name}"
          return false
        end

        # Check NS delegation in root zone
        delegated = fetch_delegated_environments(dns_config)
        if delegated.include?(env_name)
          puts '  ✓ NS delegation in root zone'
        else
          puts '  ⚠ Not delegated in root zone'
          puts "    Run: belt dns add #{env_name} && belt dns deploy"
          all_ok = false
        end

        # Check ACM certificate
        cert_status, cert_domain = fetch_acm_cert_status(env_name, env_config)
        case cert_status
        when 'ISSUED'
          puts "  ✓ ACM certificate: ISSUED (#{cert_domain})"
        when 'PENDING_VALIDATION'
          puts "  ⚠ ACM certificate: PENDING_VALIDATION (#{cert_domain})"
          if is_apex
            # Check if validation CNAME is in root zone
            validation_in_root = check_acm_validation_in_root(env_name, env_config, dns_config)
            if validation_in_root
              puts '    ✓ Validation CNAME in root zone — waiting for DNS propagation'
            else
              puts '    ✗ Validation CNAME NOT in root zone'
              puts "      Apex domains need validation CNAMEs in the root zone."
              puts "      Run: belt dns sync-validation #{env_name} && belt dns deploy"
            end
          else
            puts '    Validation CNAME should be in environment zone — waiting for DNS propagation'
          end
          all_ok = false
        when 'FAILED'
          puts "  ✗ ACM certificate: FAILED (#{cert_domain})"
          all_ok = false
        when nil
          puts '  ⚠ ACM certificate not found'
          all_ok = false
        else
          puts "  ⚠ ACM certificate: #{cert_status} (#{cert_domain})"
        end

        # Check API Gateway custom domain
        api_domain_status = fetch_api_gateway_domain_status(env_name, env_config, domain)
        case api_domain_status
        when :available
          puts '  ✓ API Gateway custom domain: available'
        when :pending
          puts '  ⚠ API Gateway custom domain: pending (waiting for cert)'
        when :not_found
          puts '  ⚠ API Gateway custom domain: not configured'
          all_ok = false
        end

        all_ok
      end

      def apex_environment?(env_name, domain)
        # Convention: 'prod' or 'production' uses the apex domain
        %w[prod production].include?(env_name)
      end

      def discover_environments(filter = nil)
        return [filter] if filter && Dir.exist?("infrastructure/#{filter}")

        Dir.glob('infrastructure/*').select do |path|
          next false unless File.directory?(path)

          env_name = File.basename(path)
          next false if %w[modules dns].include?(env_name)
          next false unless File.exist?(File.join(path, 'main.tf'))

          true
        end.map { |path| File.basename(path) }.sort
      end

      def read_domain_from_tfvars
        tfvars_path = "#{DNS_DIR}/terraform.tfvars"
        return nil unless File.exist?(tfvars_path)

        content = File.read(tfvars_path)
        match = content.match(/domain\s*=\s*"([^"]+)"/)
        match[1] if match
      end

      def load_dns_config_if_exists
        return nil unless Dir.exist?(DNS_DIR)

        load_dns_config
      rescue StandardError
        nil
      end

      def fetch_root_zone_id(dns_config)
        require 'open3'

        return nil unless Dir.exist?(DNS_DIR)

        env = {}
        env['AWS_PROFILE'] = dns_config.aws_profile if dns_config&.aws_profile?

        output, status = Dir.chdir(DNS_DIR) do
          Open3.capture2e(env, 'terraform', 'output', '-raw', 'root_zone_id')
        end

        status.success? ? output.strip : nil
      end

      def fetch_delegated_environments(dns_config)
        require 'open3'

        return [] unless Dir.exist?(DNS_DIR)

        env = {}
        env['AWS_PROFILE'] = dns_config.aws_profile if dns_config&.aws_profile?

        output, status = Dir.chdir(DNS_DIR) do
          Open3.capture2e(env, 'terraform', 'output', '-json', 'delegated_environments')
        end

        return [] unless status.success?

        begin
          JSON.parse(output)
        rescue StandardError
          []
        end
      end

      def fetch_env_zone_id(env_name, env_config)
        require 'open3'

        env_dir = "infrastructure/#{env_name}"
        return nil unless Dir.exist?(env_dir)

        env = {}
        env['AWS_PROFILE'] = env_config.aws_profile if env_config.aws_profile?

        output, status = Dir.chdir(env_dir) do
          Open3.capture2e(env, 'terraform', 'output', '-raw', 'zone_id')
        end

        status.success? && !output.strip.empty? ? output.strip : nil
      end

      def fetch_acm_cert_status(env_name, env_config)
        require 'open3'

        env_dir = "infrastructure/#{env_name}"
        return [nil, nil] unless Dir.exist?(env_dir)

        env = {}
        env['AWS_PROFILE'] = env_config.aws_profile if env_config.aws_profile?

        # Get cert ARN from terraform
        arn_output, arn_status = Dir.chdir(env_dir) do
          Open3.capture2e(env, 'terraform', 'output', '-raw', 'certificate_arn')
        end

        return [nil, nil] unless arn_status.success? && !arn_output.strip.empty?

        cert_arn = arn_output.strip

        # Get cert details from ACM
        cert_output, cert_status = Open3.capture2e(
          env,
          'aws', 'acm', 'describe-certificate',
          '--certificate-arn', cert_arn,
          '--output', 'json'
        )

        return [nil, nil] unless cert_status.success?

        cert_data = begin
          JSON.parse(cert_output)
        rescue StandardError
          nil
        end
        return [nil, nil] unless cert_data

        status = cert_data.dig('Certificate', 'Status')
        domain = cert_data.dig('Certificate', 'DomainName')
        [status, domain]
      end

      def fetch_api_gateway_domain_status(env_name, env_config, domain)
        require 'open3'

        is_apex = apex_environment?(env_name, domain)
        api_domain = is_apex ? "api.#{domain}" : "api.#{env_name}.#{domain}"

        env = {}
        env['AWS_PROFILE'] = env_config.aws_profile if env_config.aws_profile?

        output, status = Open3.capture2e(
          env,
          'aws', 'apigateway', 'get-domain-name',
          '--domain-name', api_domain,
          '--output', 'json'
        )

        return :not_found unless status.success?

        data = begin
          JSON.parse(output)
        rescue StandardError
          nil
        end
        return :not_found unless data

        # Check if it has an endpoint
        if data['regionalDomainName'] || data['distributionDomainName']
          :available
        else
          :pending
        end
      end

      def check_acm_validation_in_root(env_name, env_config, dns_config)
        require 'open3'

        validation_records = fetch_pending_acm_validation(env_name, env_config)
        return false if validation_records.nil? || validation_records.empty?

        root_zone_id = fetch_root_zone_id(dns_config)
        return false unless root_zone_id

        env = {}
        env['AWS_PROFILE'] = dns_config.aws_profile if dns_config&.aws_profile?

        # Check if the validation CNAME exists in the root zone
        validation_records.all? do |record|
          output, status = Open3.capture2e(
            env,
            'aws', 'route53', 'list-resource-record-sets',
            '--hosted-zone-id', root_zone_id,
            '--query', "ResourceRecordSets[?Name=='#{record[:name]}' && Type=='CNAME']",
            '--output', 'json'
          )

          next false unless status.success?

          records = begin
            JSON.parse(output)
          rescue StandardError
            []
          end
          records.any?
        end
      end

      # ═══════════════════════════════════════════════════════════════════════════
      # ACM validation sync helpers
      # ═══════════════════════════════════════════════════════════════════════════

      def fetch_pending_acm_validation(env_name, env_config)
        require 'open3'

        env_dir = "infrastructure/#{env_name}"
        return nil unless Dir.exist?(env_dir)

        env = {}
        env['AWS_PROFILE'] = env_config.aws_profile if env_config.aws_profile?

        # Get cert ARN from terraform
        arn_output, arn_status = Dir.chdir(env_dir) do
          Open3.capture2e(env, 'terraform', 'output', '-raw', 'certificate_arn')
        end

        return nil unless arn_status.success? && !arn_output.strip.empty?

        cert_arn = arn_output.strip

        # Get cert details from ACM
        cert_output, cert_status = Open3.capture2e(
          env,
          'aws', 'acm', 'describe-certificate',
          '--certificate-arn', cert_arn,
          '--output', 'json'
        )

        return nil unless cert_status.success?

        cert_data = begin
          JSON.parse(cert_output)
        rescue StandardError
          nil
        end
        return nil unless cert_data

        # Extract validation options
        validation_options = cert_data.dig('Certificate', 'DomainValidationOptions') || []

        # Return records that need DNS validation
        validation_options.filter_map do |opt|
          next unless opt['ValidationMethod'] == 'DNS'
          next if opt['ValidationStatus'] == 'SUCCESS'

          resource_record = opt['ResourceRecord']
          next unless resource_record

          {
            name: resource_record['Name'],
            type: resource_record['Type'],
            value: resource_record['Value']
          }
        end
      end

      def create_validation_cname_in_root_zone(root_zone_id, record, dns_config)
        require 'open3'

        env = {}
        env['AWS_PROFILE'] = dns_config.aws_profile if dns_config&.aws_profile?

        # Create a change batch to upsert the CNAME
        change_batch = {
          'Changes' => [
            {
              'Action' => 'UPSERT',
              'ResourceRecordSet' => {
                'Name' => record[:name],
                'Type' => 'CNAME',
                'TTL' => 300,
                'ResourceRecords' => [
                  { 'Value' => record[:value] }
                ]
              }
            }
          ]
        }

        require 'tempfile'
        Tempfile.create(['change-batch', '.json']) do |f|
          f.write(JSON.generate(change_batch))
          f.flush

          output, status = Open3.capture2e(
            env,
            'aws', 'route53', 'change-resource-record-sets',
            '--hosted-zone-id', root_zone_id,
            '--change-batch', "file://#{f.path}"
          )

          unless status.success?
            puts "     ⚠ Failed to create validation CNAME: #{record[:name]}" unless @quiet
            puts "       #{output}" unless @quiet
          end
        end
      end

      # ═══════════════════════════════════════════════════════════════════════════
      # Original private methods
      # ═══════════════════════════════════════════════════════════════════════════

      def templates
        {
          'main.tf.erb' => 'main.tf',
          'backend.tf.erb' => 'backend.tf',
          'variables.tf.erb' => 'variables.tf',
          'terraform.tfvars.erb' => 'terraform.tfvars',
          'outputs.tf.erb' => 'outputs.tf',
          'belt.rb.erb' => 'belt.rb'
        }
      end

      def write_template(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
      end

      def load_dns_config
        # Load config from infrastructure/dns/belt.rb
        # EnvironmentConfig.load expects (env_name, infra_dir:) where the path
        # is infra_dir/env_name/belt.rb. We pass 'dns' as env_name.
        EnvironmentConfig.load('dns')
      end

      def run_terraform(action, env_config, *extra_args)
        cmd = ['terraform', action] + extra_args
        env = {}

        if env_config.aws_profile?
          env['AWS_PROFILE'] = env_config.aws_profile
          puts "Using AWS profile: #{env_config.aws_profile}" if action == 'init'
        end

        system(env, *cmd) || begin
          puts "\n✗ terraform #{action} failed"
          exit 1
        end
      end

      def fetch_ns_records(env_name)
        env_dir = "infrastructure/#{env_name}"
        env_config = EnvironmentConfig.load(env_name)

        env = {}
        env['AWS_PROFILE'] = env_config.aws_profile if env_config.aws_profile?

        Dir.chdir(env_dir) do
          # Try terraform output first
          output, status = Open3.capture2e(env, 'terraform', 'output', '-json', 'name_servers')
          if status.success?
            begin
              return JSON.parse(output)
            rescue JSON::ParserError
              # Fall through to state inspection
            end
          end

          # Fallback: inspect state for the zone
          output, status = Open3.capture2e(env, 'terraform', 'state', 'show', '-json',
                                           'module.app.aws_route53_zone.app[0]')
          return nil unless status.success?

          begin
            state = JSON.parse(output)
            state.dig('values', 'name_servers')
          rescue JSON::ParserError
            nil
          end
        end
      end

      def update_tfvars(path, env_name, ns_records)
        content = File.read(path)

        # Format the NS records for HCL
        ns_list = ns_records.map { |ns| "    \"#{ns}\"" }.join(",\n")
        new_entry = "  #{env_name} = [\n#{ns_list}\n  ]"

        # Match the actual HCL block, not commented examples.
        # Look for environment_zones = { at the start of a line (not preceded by #)
        hcl_block_pattern = /^environment_zones\s*=\s*\{([^}]*)\}/m

        if content =~ hcl_block_pattern
          existing = ::Regexp.last_match(1).strip

          if existing.empty?
            # Empty block - replace with our entry
            content.sub!(/^environment_zones\s*=\s*\{\s*\}/m, "environment_zones = {\n#{new_entry}\n}")
          elsif existing.include?("#{env_name} =")
            # Environment already exists - update it
            # Match env name at start of line (with optional leading whitespace) to avoid comment matches
            content.sub!(/^(\s*)#{env_name}\s*=\s*\[[^\]]*\]/m, "\\1#{env_name} = [\n#{ns_list}\n  ]")
          else
            # Add to existing entries (insert after opening brace)
            content.sub!(/^environment_zones\s*=\s*\{/m, "environment_zones = {\n#{new_entry}")
          end
        end

        File.write(path, content)
      end

      def remove_env_from_tfvars(path, env_name)
        content = File.read(path)

        # Match the environment entry: "  env_name = [\n    ...\n  ]" with optional trailing comma
        # The entry can be followed by another entry, a closing brace, or whitespace
        #
        # Pattern breakdown:
        # - ^(\s*)#{env_name}\s*= matches "  env_name =" at start of line
        # - \s*\[\s* matches " [" with optional whitespace
        # - [^\]]* matches everything inside brackets (the NS records)
        # - \]\s*,?\s* matches "]" with optional trailing comma and whitespace
        # - (?=\n|\s*[}\w]) lookahead for newline or closing brace/next entry
        entry_pattern = /^\s*#{Regexp.escape(env_name)}\s*=\s*\[[^\]]*\]\s*,?\s*\n?/m

        content.gsub!(entry_pattern, '')

        # Clean up any double newlines that may have been created
        content.gsub!(/\n{3,}/, "\n\n")

        # If the environment_zones block is now empty (just whitespace), clean it up
        content.gsub!(/^environment_zones\s*=\s*\{\s*\n\s*\}/, 'environment_zones = {}')

        File.write(path, content)
      end

      # Resolve the state bucket name to use in backend.tf.
      # Priority: existing sibling backend.tf → AWS account ID → bare placeholder.
      def resolve_state_bucket
        bucket_from_sibling || bucket_from_aws || 'belt-terraform-state'
      end

      # Resolve state bucket for a specific AWS profile.
      # If profile is explicitly provided, uses that profile's account ID directly.
      # Otherwise falls back to existing sibling backend.tf or current credentials.
      def resolve_state_bucket_for_profile(profile)
        if profile
          # Explicit profile = derive bucket from that profile's account ID
          # Do NOT fall back to sibling backends — they're likely different accounts
          bucket_from_aws_profile(profile) || 'belt-terraform-state'
        else
          # No profile = use existing sibling or current credentials
          bucket_from_sibling || bucket_from_aws_profile(nil) || 'belt-terraform-state'
        end
      end

      def bucket_from_sibling
        Dir.glob('infrastructure/*/backend.tf').each do |f|
          match = File.read(f).match(/bucket\s*=\s*"([^"]+)"/)
          next unless match
          # Skip the bare placeholder — it means state wasn't set up yet
          return match[1] unless match[1] == 'belt-terraform-state'
        end
        nil
      end

      def bucket_from_aws
        bucket_from_aws_profile(nil)
      end

      def bucket_from_aws_profile(profile)
        require 'open3'
        cmd = %w[aws sts get-caller-identity]
        cmd += ['--profile', profile] if profile
        output, status = Open3.capture2e(*cmd)
        return nil unless status.success?

        data = begin
          JSON.parse(output)
        rescue StandardError
          nil
        end
        return nil unless data&.dig('Account')

        "belt-terraform-state-#{data['Account']}"
      end

      # Ensure the state bucket exists, creating it if necessary.
      # Uses belt setup state --aws-profile for convention over configuration.
      def ensure_state_bucket_exists(bucket)
        return if bucket == 'belt-terraform-state' # Placeholder means no credentials
        return if bucket_exists?(bucket)

        puts "State bucket #{bucket} not found. Creating it..." unless @quiet
        args = []
        args += ['--aws-profile', @aws_profile] if @aws_profile
        SetupCommand.new(args, quiet: @quiet, aws_profile: @aws_profile).run_state_setup
      end

      def bucket_exists?(bucket)
        require 'open3'
        cmd = ['aws', 's3api', 'head-bucket', '--bucket', bucket]
        cmd += ['--profile', @aws_profile] if @aws_profile
        _, status = Open3.capture2e(*cmd)
        status.success?
      end

      # Verify a Route 53 hosted zone exists in AWS.
      # env is a hash with optional AWS_PROFILE for the aws CLI.
      def zone_exists_in_aws?(zone_id, env = {})
        require 'open3'
        cmd = ['aws', 'route53', 'get-hosted-zone', '--id', zone_id]
        cmd += ['--profile', env['AWS_PROFILE']] if env['AWS_PROFILE']
        _, status = Open3.capture2e(*cmd)
        status.success?
      end
    end
  end
end
