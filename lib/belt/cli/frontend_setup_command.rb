# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'
require_relative 'env_resolver'

module Belt
  module CLI
    class FrontendSetupCommand
      TEMPLATE_DIR = File.expand_path('../../templates/frontend_infra', __dir__)

      include AppDetection

      def self.run(args)
        env = EnvResolver.resolve(args)

        if env.nil?
          puts 'Usage: belt setup frontend <environment>'
          puts "\nGenerates S3 + CloudFront Terraform for frontend hosting."
          puts 'You can also set BELT_ENV to skip the environment argument.'
          puts "\nExamples:"
          puts '  belt setup frontend wups'
          puts '  belt setup frontend dev01'
          puts '  BELT_ENV=wups belt setup frontend'
          exit 1
        end

        new(env).run
      end

      def initialize(env, quiet: false)
        @env = env
        @app_name = detect_app_name
        @env_dir = "infrastructure/#{@env}"
        @quiet = quiet
      end

      def run
        validate!
        generate_frontend_tf
        update_main_tf_frontend_urls
        return if @quiet

        puts "\n✓ Frontend infrastructure generated for '#{@env}'!"
        puts "\nRun `belt apply #{@env}` to create the S3 bucket and CloudFront distribution."
        puts "Then `belt deploy frontend #{@env}` to build and deploy."
      end

      private

      def validate!
        return if Dir.exist?(@env_dir)

        abort "Error: Environment '#{@env}' not found at #{@env_dir}/.\n" \
              "Create it with: belt generate environment #{@env}"
      end

      def generate_frontend_tf
        dest = File.join(@env_dir, 'frontend.tf')
        template_path = File.join(TEMPLATE_DIR, 'frontend.tf.erb')
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest, content)
        puts "  create  #{dest}" unless @quiet
      end

      def update_main_tf_frontend_urls
        main_tf = File.join(@env_dir, 'main.tf')
        return unless File.exist?(main_tf)

        content = File.read(main_tf)
        cloudfront_url = '"https://${aws_cloudfront_distribution.frontend.domain_name}"'

        # Already patched — skip
        return if content.include?('aws_cloudfront_distribution.frontend.domain_name')

        # Match any frontend_urls line (hardcoded list or conditional expression)
        new_frontend_urls = <<~HCL.chomp
          frontend_urls     = concat(
            [#{cloudfront_url}],
            var.environment == "prod" ? [] : ["http://localhost:3000"]
          )
        HCL

        replaced = content.sub(
          /^(\s*)frontend_urls\s*=\s*.+$/,
          new_frontend_urls
        )

        if replaced != content
          File.write(main_tf, replaced)
          puts "  update  #{main_tf} (added CloudFront URL to frontend_urls)" unless @quiet
        end
      end
    end
  end
end
