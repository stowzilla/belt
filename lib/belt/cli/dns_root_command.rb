# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'

module Belt
  module CLI
    class DnsRootCommand
      TEMPLATE_DIR = File.expand_path('../../templates/dns_root', __dir__)

      include AppDetection

      def self.run(args)
        new.generate
      end

      def initialize(quiet: false)
        @app_name = detect_app_name
        @quiet = quiet
        @state_bucket = resolve_state_bucket
      end

      def generate
        dest_dir = 'infrastructure/dns-root'

        if Dir.exist?(dest_dir)
          puts "dns-root already exists at #{dest_dir}/"
          puts "\nTo configure it:"
          puts "  1. Edit #{dest_dir}/terraform.tfvars with your domain and environment NS records"
          puts '  2. Run: cd infrastructure/dns-root && terraform init && terraform apply'
          exit 1
        end

        puts 'Creating dns-root infrastructure...' unless @quiet
        FileUtils.mkdir_p(dest_dir)

        templates.each do |template_name, dest_file|
          dest_path = File.join(dest_dir, dest_file)
          write_template(template_name, dest_path)
          puts "  create  #{dest_path}" unless @quiet
        end

        return if @quiet

        puts "\n✓ dns-root infrastructure created!"
        puts "\nThis manages your root domain and delegates subdomains to per-environment zones."
        puts "\nNext steps:"
        puts '  1. Deploy your environments first (if not already deployed):'
        puts '       belt deploy dev'
        puts '       belt deploy staging'
        puts ''
        puts '  2. Get each environment\'s NS records:'
        puts '       cd infrastructure/dev && terraform output name_servers'
        puts '       cd infrastructure/staging && terraform output name_servers'
        puts ''
        puts "  3. Edit #{dest_dir}/terraform.tfvars:"
        puts '       - Set your domain'
        puts '       - Add each environment\'s NS records to environment_zones'
        puts ''
        puts '  4. Deploy the dns-root:'
        puts "       cd #{dest_dir}"
        puts '       terraform init'
        puts '       terraform apply'
        puts ''
        puts '  5. Update your registrar\'s NS records to the root_name_servers output'
      end

      private

      def templates
        {
          'main.tf.erb' => 'main.tf',
          'backend.tf.erb' => 'backend.tf',
          'variables.tf.erb' => 'variables.tf',
          'terraform.tfvars.erb' => 'terraform.tfvars',
          'outputs.tf.erb' => 'outputs.tf'
        }
      end

      def write_template(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
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
