# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'
require_relative 'frontend_registry'
require_relative 'frontend_setup_command'

module Belt
  module CLI
    class EnvironmentCommand
      TEMPLATE_DIR = File.expand_path('../../templates/environment', __dir__)

      include AppDetection

      def self.run(args)
        env_name = args.shift

        if env_name.nil? || env_name.empty?
          puts 'Usage: belt generate environment <name>'
          puts "\nExamples:"
          puts '  belt generate environment dev01'
          puts '  belt generate environment staging'
          puts '  belt generate environment prod'
          exit 1
        end

        new(env_name).generate
      end

      def initialize(env_name, quiet: false, domain: nil, announce: true)
        @env_name = env_name.downcase.gsub(/[^a-z0-9_-]/, '')
        @app_name = detect_app_name
        @domain = domain
        @quiet = quiet
        @announce = announce
        @state_bucket = resolve_state_bucket
      end

      def generate
        dest_dir = "infrastructure/#{@env_name}"

        if Dir.exist?(dest_dir)
          puts "Environment '#{@env_name}' already exists at #{dest_dir}/"
          exit 1
        end

        puts "Creating environment: #{@env_name}" unless @quiet
        FileUtils.mkdir_p(dest_dir)

        templates.each do |template_name, dest_file|
          dest_path = File.join(dest_dir, dest_file)
          write_template(template_name, dest_path)
          puts "  create  #{dest_path}" unless @quiet
        end

        append_extra_frontend_outputs(File.join(dest_dir, 'outputs.tf'))

        return if @quiet || !@announce

        puts "\n✓ Environment '#{@env_name}' created!"
        puts "\nNext steps:"
        puts "  cd #{dest_dir}"
        puts '  terraform init'
        puts '  terraform plan'
        puts '  terraform apply'
        puts "\nTo configure a custom domain, set `domain` in #{dest_dir}/terraform.tfvars:"
        puts '  domain = "myapp.com"'
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

      def append_extra_frontend_outputs(outputs_file)
        FrontendRegistry.new.all.each do |frontend|
          next if frontend.tf_name == 'frontend'

          FrontendSetupCommand.append_env_outputs_for(frontend, outputs_file)
        end
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
