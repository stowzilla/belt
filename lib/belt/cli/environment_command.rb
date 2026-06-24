# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'

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

      def initialize(env_name)
        @env_name = env_name.downcase.gsub(/[^a-z0-9_-]/, '')
        @app_name = detect_app_name
      end

      def generate
        dest_dir = "infrastructure/#{@env_name}"

        if Dir.exist?(dest_dir)
          puts "Environment '#{@env_name}' already exists at #{dest_dir}/"
          exit 1
        end

        puts "Creating environment: #{@env_name}"
        FileUtils.mkdir_p(dest_dir)

        templates.each do |template_name, dest_file|
          dest_path = File.join(dest_dir, dest_file)
          write_template(template_name, dest_path)
          puts "  create  #{dest_path}"
        end

        puts "\n✓ Environment '#{@env_name}' created!"
        puts "\nNext steps:"
        puts "  cd #{dest_dir}"
        puts '  terraform init'
        puts '  terraform plan'
        puts '  terraform apply'
      end

      private

      def templates
        {
          'main.tf.erb' => 'main.tf',
          'backend.tf.erb' => 'backend.tf',
          'variables.tf.erb' => 'variables.tf',
          'terraform.tfvars.erb' => 'terraform.tfvars'
        }
      end

      def write_template(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
      end
    end
  end
end
