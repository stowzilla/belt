# frozen_string_literal: true

require 'fileutils'
require 'erb'
require 'json'
require_relative 'app_detection'
require_relative 'environment_config'

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
          new.generate
        when 'add'
          new.add_environment(args)
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
            help                Show this help

          Examples:
            belt dns deploy                 # Deploy the root zone
            belt dns generate               # Scaffold infrastructure/dns
            belt dns add staging            # Add staging's NS records to tfvars

          The dns directory manages your root domain and delegates subdomains to
          per-environment hosted zones. Each environment (dev, staging, prod) gets
          its own Route 53 zone, and this root zone delegates to each of them.

          Workflow:
            1. belt deploy dev              # Deploy environments first
            2. belt dns generate            # Create infrastructure/dns
            3. belt dns add dev             # Add dev's NS records
            4. belt dns deploy              # Deploy root zone
            5. Update registrar NS records to output values
        HELP
      end

      def initialize(quiet: false)
        @app_name = detect_app_name
        @quiet = quiet
        @state_bucket = resolve_state_bucket
      end

      # --- Generate ---
      def generate
        if Dir.exist?(DNS_DIR)
          puts "dns infrastructure already exists at #{DNS_DIR}/"
          puts "\nTo configure it:"
          puts "  1. Edit #{DNS_DIR}/terraform.tfvars with your domain and environment NS records"
          puts '  2. Run: belt dns deploy'
          exit 1
        end

        puts 'Creating dns infrastructure...' unless @quiet
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
          else
            print "\nApply this plan? [y/N] "
            answer = $stdin.gets&.strip&.downcase
            if %w[y yes].include?(answer)
              run_terraform('apply', env_config, 'tfplan')
            else
              puts 'Aborted.'
              exit 1
            end
          end
        end
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

      private

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
        belt_rb = File.join(DNS_DIR, 'belt.rb')
        return {} unless File.exist?(belt_rb)

        EnvironmentConfig.load(belt_rb)
      end

      def run_terraform(action, env_config, *extra_args)
        cmd = ['terraform', action] + extra_args
        env = {}

        if env_config[:aws_profile]
          env['AWS_PROFILE'] = env_config[:aws_profile]
          puts "Using AWS profile: #{env_config[:aws_profile]}" if action == 'init'
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

        # Check if environment_zones already has entries
        if content =~ /environment_zones\s*=\s*\{([^}]*)\}/m
          existing = ::Regexp.last_match(1).strip

          if existing.empty?
            # Empty block - replace with our entry
            content.sub!(/environment_zones\s*=\s*\{\s*\}/, "environment_zones = {\n#{new_entry}\n}")
          elsif existing.include?("#{env_name} =")
            # Environment already exists - update it
            content.sub!(/#{env_name}\s*=\s*\[[^\]]*\]/m, "#{env_name} = [\n#{ns_list}\n  ]")
          else
            # Add to existing entries
            content.sub!(/environment_zones\s*=\s*\{/m, "environment_zones = {\n#{new_entry}")
          end
        end

        File.write(path, content)
      end

      # Resolve the state bucket name to use in backend.tf.
      # Priority: existing sibling backend.tf → AWS account ID → bare placeholder.
      def resolve_state_bucket
        bucket_from_sibling || bucket_from_aws || 'belt-terraform-state'
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
        require 'open3'
        output, status = Open3.capture2e('aws', 'sts', 'get-caller-identity')
        return nil unless status.success?

        data = begin
          JSON.parse(output)
        rescue StandardError
          nil
        end
        return nil unless data&.dig('Account')

        "belt-terraform-state-#{data['Account']}"
      end
    end
  end
end
