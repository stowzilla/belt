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

      def initialize(_env = nil, quiet: false)
        @app_name = detect_app_name
        @quiet = quiet
      end

      def run
        validate!
        generate_frontend_tf
        ensure_cloudfront_cors
        return if @quiet

        puts "\n✓ Frontend infrastructure generated in #{MODULE_DIR}!"
        puts "\nRun `belt deploy` to create the S3 bucket and CloudFront distribution."
        puts 'Then `belt deploy frontend` to build and deploy.'
      end

      private

      def validate!
        return if Dir.exist?(MODULE_DIR)

        abort "Error: Module directory not found at #{MODULE_DIR}/.\n" \
              'Run `belt new` to create a project with the correct structure.'
      end

      def generate_frontend_tf
        dest = File.join(MODULE_DIR, 'frontend.tf')
        template_path = File.join(TEMPLATE_DIR, 'frontend.tf.erb')
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest, content)
        puts "  create  #{dest}" unless @quiet
      end

      # Wire CloudFront origin into conveyor_belt frontend_urls so SPA→API CORS works.
      def ensure_cloudfront_cors
        main_tf = File.join(MODULE_DIR, 'main.tf')
        return unless File.exist?(main_tf)

        content = File.read(main_tf)
        return if content.include?('aws_cloudfront_distribution.frontend.domain_name')

        simple = /^(\s*)frontend_urls\s*=\s*var\.frontend_urls\s*$/
        unless content.match?(simple)
          puts "  skip    #{main_tf} (add CloudFront to frontend_urls manually for CORS)" unless @quiet
          return
        end

        content = content.sub(simple) do
          indent = Regexp.last_match(1)
          <<~TF.chomp
            #{indent}frontend_urls = concat(
            #{indent}  var.frontend_urls,
            #{indent}  ["https://${aws_cloudfront_distribution.frontend.domain_name}"]
            #{indent})
          TF
        end
        File.write(main_tf, content)
        puts "  update  #{main_tf} (CloudFront CORS)" unless @quiet
      end
    end
  end
end
