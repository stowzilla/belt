# frozen_string_literal: true

require 'fileutils'
require 'erb'
require 'open3'
require 'json'
require_relative 'app_detection'

module Belt
  module CLI
    class DnsCommand
      TEMPLATE_DIR = File.expand_path('../../templates/root_zone', __dir__)

      include AppDetection

      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @domain = nil
        @quiet = false
        parse_args(args)
        @app_name = detect_app_name
        @region = detect_region
        @state_bucket = resolve_state_bucket
      end

      def run
        if @domain.nil?
          puts usage
          exit 1
        end

        dest_dir = 'infrastructure/root'

        if Dir.exist?(dest_dir)
          puts "Root zone already exists at #{dest_dir}/"
          puts "\nTo see current outputs:"
          puts "  cd #{dest_dir} && terraform output"
          exit 1
        end

        puts "Creating root DNS zone for: #{@domain}"
        FileUtils.mkdir_p(dest_dir)

        templates.each do |template_name, dest_file|
          dest_path = File.join(dest_dir, dest_file)
          write_template(template_name, dest_path)
          puts "  create  #{dest_path}" unless @quiet
        end

        puts "\n✓ Root zone created!"
        puts "\nDeploy it:"
        puts "  cd infrastructure/root"
        puts "  terraform init"
        puts "  terraform apply"
        puts "\nAfter applying, configure your registrar with the output name_servers,"
        puts "then add root_zone_id to each environment's terraform.tfvars:"
        puts "  root_zone_id = \"<zone_id from terraform output>\""
      end

      private

      def usage
        <<~USAGE
          Usage: belt setup dns <domain>

          Creates a root DNS zone for multi-environment deployments.

          The root zone manages your domain's NS records and delegates
          subdomains to per-environment zones automatically.

          Example:
            belt setup dns myapp.com

          After setup:
            1. Deploy: cd infrastructure/root && terraform init && terraform apply
            2. Configure your registrar with the output name_servers
            3. Add root_zone_id to each environment's terraform.tfvars
        USAGE
      end

      def parse_args(args)
        while (arg = args.shift)
          case arg
          when '--quiet', '-q'
            @quiet = true
          when '--help', '-h'
            puts usage
            exit 0
          else
            @domain = arg unless arg.start_with?('-')
          end
        end
      end

      def templates
        {
          'main.tf.erb' => 'main.tf',
          'backend.tf.erb' => 'backend.tf',
          'terraform.tfvars.erb' => 'terraform.tfvars'
        }
      end

      def write_template(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
      end

      def detect_region
        Dir.glob('infrastructure/*/backend.tf').each do |f|
          match = File.read(f).match(/region\s*=\s*"([^"]+)"/)
          return match[1] if match
        end
        'us-east-1'
      end

      def resolve_state_bucket
        Dir.glob('infrastructure/*/backend.tf').each do |f|
          match = File.read(f).match(/bucket\s*=\s*"([^"]+)"/)
          return match[1] if match && match[1] != 'belt-terraform-state'
        end
        bucket_from_aws || 'belt-terraform-state'
      end

      def bucket_from_aws
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
