# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'
require_relative 'env_resolver'
require_relative 'frontend_registry'

module Belt
  module CLI
    class FrontendSetupCommand
      TEMPLATE_DIR = File.expand_path('../../templates/module', __dir__)
      MODULE_DIR = 'infrastructure/modules/app'

      include AppDetection

      def self.run(args)
        # Environment arg is no longer needed since frontend.tf goes in the module,
        # but we still accept it for backwards compat (just ignore it).
        name = FrontendRegistry.extract_flag!(args, '--name')
        name ||= FrontendRegistry.extract_flag!(args, '--frontend')
        _env = EnvResolver.resolve(args)
        frontend = name ? FrontendRegistry.new.resolve!(name) : nil
        new(nil, frontend: frontend).run
      end

      def self.append_env_outputs_for(frontend, outputs_file)
        return unless File.exist?(outputs_file)
        return if frontend.tf_name == 'frontend'

        content = File.read(outputs_file)
        prefix = frontend.output_prefix
        return if content.include?("output \"#{prefix}_bucket_name\"")

        File.write(outputs_file, content + extra_env_outputs(frontend))
      end

      def self.extra_env_outputs(frontend)
        prefix = frontend.output_prefix
        label = frontend.name
        <<~HCL

          output "#{prefix}_bucket_name" {
            description = "S3 bucket for #{label} frontend assets"
            value       = try(module.app.#{prefix}_bucket_name, "")
          }

          output "#{prefix}_distribution_id" {
            description = "CloudFront distribution ID for #{label} frontend"
            value       = try(module.app.#{prefix}_distribution_id, "")
          }

          output "#{prefix}_url" {
            description = "#{label} frontend URL"
            value       = try(module.app.#{prefix}_url, "")
          }
        HCL
      end

      def initialize(_env = nil, quiet: false, frontend: nil)
        @app_name = detect_app_name
        @quiet = quiet
        @frontend = frontend || Frontend.new(name: 'frontend', path: 'frontend', default: true)
        @tf_name = @frontend.tf_name
        @output_prefix = @frontend.output_prefix
        @include_dns = @frontend.slug == 'frontend'
        @bucket_slug = @frontend.slug == 'frontend' ? 'frontend' : "#{@frontend.slug.tr('_', '-')}-frontend"
      end

      def run
        validate!
        generate_frontend_tf
        ensure_cloudfront_cors
        append_env_outputs
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
        dest = File.join(MODULE_DIR, "#{@tf_name}.tf")
        template_path = File.join(TEMPLATE_DIR, 'frontend.tf.erb')
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest, content)
        puts "  create  #{dest}" unless @quiet
      end

      def append_env_outputs
        Dir.glob('infrastructure/*/outputs.tf').reject { |f| f.include?('modules') }.each do |file|
          before = File.read(file)
          self.class.append_env_outputs_for(@frontend, file)
          next if File.read(file) == before

          env_name = File.basename(File.dirname(file))
          puts "  update  #{file} (#{@frontend.name} frontend outputs for #{env_name})" unless @quiet
        end
      end

      # Wire CloudFront origin into conveyor_belt frontend_urls so SPA→API CORS works.
      # Handles common scaffold shapes so users never need the tutorial's manual CORS fix.
      def ensure_cloudfront_cors
        main_tf = File.join(MODULE_DIR, 'main.tf')
        return unless File.exist?(main_tf)

        content = File.read(main_tf)
        ref = "aws_cloudfront_distribution.#{@tf_name}.domain_name"
        return if content.include?(ref)

        cf_line = %(["https://${#{ref}}"])

        # Already a concat of CloudFront origins — insert this distribution.
        if content.match?(/frontend_urls\s*=\s*concat\(/) &&
           content.include?('aws_cloudfront_distribution.')
          content = content.sub(/(frontend_urls\s*=\s*concat\(\n)/, "\\1    #{cf_line},\n")
          File.write(main_tf, content)
          puts "  update  #{main_tf} (CloudFront CORS: #{@tf_name})" unless @quiet
          return
        end

        replacement = lambda do |indent|
          <<~TF.chomp
            #{indent}# CloudFront first so SPA→API CORS works out of the box.
            #{indent}frontend_urls = concat(
            #{indent}  #{cf_line},
            #{indent}  var.frontend_urls
            #{indent})
          TF
        end

        # `frontend_urls = var.frontend_urls`
        simple = /^(\s*)frontend_urls\s*=\s*var\.frontend_urls\s*$/
        if content.match?(simple)
          content = content.sub(simple) { replacement.call(Regexp.last_match(1)) }
          File.write(main_tf, content)
          puts "  update  #{main_tf} (CloudFront CORS)" unless @quiet
          return
        end

        # `frontend_urls = concat(var.frontend_urls)` or multi-line concat without CloudFront
        concat_only = /^(\s*)frontend_urls\s*=\s*concat\(\s*\n?\s*var\.frontend_urls\s*\n?\s*\)\s*$/m
        if content.match?(concat_only)
          content = content.sub(concat_only) { replacement.call(Regexp.last_match(1)) }
          File.write(main_tf, content)
          puts "  update  #{main_tf} (CloudFront CORS)" unless @quiet
          return
        end

        puts "  skip    #{main_tf} (add CloudFront to frontend_urls manually for CORS)" unless @quiet
      end
    end
  end
end
