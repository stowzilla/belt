# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'
require_relative 'env_resolver'

module Belt
  module CLI
    class FrontendSetupCommand
      TEMPLATE_DIR = File.expand_path('../../templates/module', __dir__)
      MODULE_DIR = 'infrastructure/modules/app'

      include AppDetection

      def self.run(args)
        # Environment arg is no longer needed since frontend.tf goes in the module,
        # but we still accept it for backwards compat (just ignore it).
        _env = EnvResolver.resolve(args)
        new.run
      end

      def initialize(env = nil, quiet: false)
        @app_name = detect_app_name
        @quiet = quiet
      end

      def run
        validate!
        generate_frontend_tf
        return if @quiet

        puts "\n✓ Frontend infrastructure generated in #{MODULE_DIR}!"
        puts "\nRun `belt deploy` to create the S3 bucket and CloudFront distribution."
        puts "Then `belt deploy frontend` to build and deploy."
      end

      private

      def validate!
        return if Dir.exist?(MODULE_DIR)

        abort "Error: Module directory not found at #{MODULE_DIR}/.\n" \
              "Run `belt new` to create a project with the correct structure."
      end

      def generate_frontend_tf
        dest = File.join(MODULE_DIR, 'frontend.tf')
        template_path = File.join(TEMPLATE_DIR, 'frontend.tf.erb')
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest, content)
        puts "  create  #{dest}" unless @quiet
      end
    end
  end
end
