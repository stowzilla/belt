# frozen_string_literal: true

require 'fileutils'
require 'erb'

module Belt
  module CLI
    class FrontendSetupCommand
      TEMPLATE_DIR = File.expand_path('../../templates/frontend_infra', __dir__)

      def self.run(args)
        env = args.shift

        if env.nil? || env.start_with?('-')
          puts "Usage: belt setup frontend <environment>"
          puts "\nGenerates S3 + CloudFront Terraform for frontend hosting."
          puts "\nExamples:"
          puts "  belt setup frontend wups"
          puts "  belt setup frontend dev01"
          exit 1
        end

        new(env).run
      end

      def initialize(env)
        @env = env
        @app_name = detect_app_name
        @env_dir = "infrastructure/#{@env}"
      end

      def run
        validate!
        generate_frontend_tf
        puts "\n✓ Frontend infrastructure generated for '#{@env}'!"
        puts "\nRun `belt apply #{@env}` to create the S3 bucket and CloudFront distribution."
        puts "Then `belt deploy frontend #{@env}` to build and deploy."
      end

      private

      def validate!
        unless Dir.exist?(@env_dir)
          abort "Error: Environment '#{@env}' not found at #{@env_dir}/.\n" \
                "Create it with: belt generate environment #{@env}"
        end
      end

      def generate_frontend_tf
        dest = File.join(@env_dir, 'frontend.tf')
        template_path = File.join(TEMPLATE_DIR, 'frontend.tf.erb')
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest, content)
        puts "  create  #{dest}"
      end

      def detect_app_name
        routes_file = 'infrastructure/routes.tf.rb'
        if File.exist?(routes_file)
          match = File.read(routes_file).match(/namespace :(\w+)/)
          return match[1] if match
        end
        File.basename(Dir.pwd)
      end
    end
  end
end
