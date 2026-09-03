# frozen_string_literal: true

require 'shellwords'
require 'open3'
require_relative 'app_detection'
require_relative 'env_resolver'
require_relative 'environment_config'
require_relative 'frontend_env_map'
require_relative 'frontend_registry'
require_relative 'terraform_command'

module Belt
  module CLI
    class FrontendDeployCommand
      include AppDetection

      def self.run(args)
        frontend_name = FrontendRegistry.extract_flag!(args, '--frontend')
        env = EnvResolver.resolve(args)

        if env.nil?
          puts 'Usage: belt deploy frontend <environment> [--frontend NAME]'
          puts "\nBuilds frontend app(s) and deploys to S3 + invalidates CloudFront."
          puts 'You can also set BELT_ENV to skip the environment argument.'
          puts "\nWith multiple frontends (config/frontends.yml):"
          puts '  belt deploy frontend wups                  # deploy all'
          puts '  belt deploy frontend wups --frontend ops   # deploy one'
          puts "\nExamples:"
          puts '  belt deploy frontend wups'
          puts '  belt deploy frontend dev01'
          puts '  BELT_ENV=wups belt deploy frontend'
          exit 1
        end

        leftover = args.reject { |a| a.start_with?('-') }
        frontend_name ||= leftover.shift

        if frontend_name
          frontend = FrontendRegistry.new.resolve!(frontend_name)
          new(env, frontend: frontend).run
        else
          deploy_all(env)
        end
      end

      def self.deploy_all(env)
        frontends = FrontendRegistry.new.existing
        abort FrontendRegistry.new.empty_message if frontends.empty?

        frontends.each_with_index do |frontend, index|
          puts if index.positive?
          new(env, frontend: frontend).run
        end
      end

      def initialize(env, frontend: nil)
        @env = env
        @app_name = detect_app_name
        @infra_dir = TerraformCommand.find_infrastructure_dir || 'infrastructure'
        @env_dir = File.join(@infra_dir, @env)
        @frontend = frontend || FrontendRegistry.new.resolve!
      end

      def run
        load_and_apply_env_config!
        validate!
        puts "━━━ #{@frontend.label} (#{@frontend.path}/) ━━━"
        build_frontend
        sync_to_s3
        invalidate_cloudfront
        url = fetch_frontend_url
        puts "\n✅ #{@frontend.label.capitalize} deployed to #{@env}!"
        puts "   #{url}" if url
      end

      private

      # Load infrastructure/<env>/belt.rb and apply its aws_profile + env vars
      # to the current process. Without this, `terraform output` can't reach the
      # S3 state backend (403), fetch_tf_output returns nil, and the deploy aborts
      # with a misleading "Could not determine S3 bucket" error. The full
      # `belt deploy` path applies this before invoking the frontend deploy;
      # standalone `belt deploy frontend` must do it too.
      def load_and_apply_env_config!
        EnvironmentConfig.load(@env, infra_dir: @infra_dir).apply!
      end

      def validate!
        unless Dir.exist?(@frontend.path)
          abort "Error: No #{@frontend.path}/ directory found. " \
                'Run `belt generate frontend react --name ' \
                "#{@frontend.name} --path #{@frontend.path}` first."
        end
        return if File.exist?(@frontend.package_json)

        abort "Error: #{@frontend.package_json} not found."
      end

      def build_frontend
        puts '📦 Installing dependencies...'
        install_cmd = File.exist?(File.join(@frontend.path, 'package-lock.json')) ? %w[npm ci] : %w[npm install]
        run!(*install_cmd, chdir: @frontend.path)

        puts "🏗️  Building #{@frontend.label}..."
        env = frontend_build_env
        puts "   Injecting env: #{env.keys.sort.join(', ')}" if env.any?
        run!(env, 'npm', 'run', 'build', chdir: @frontend.path)
      end

      def frontend_build_env
        FrontendEnvMap.new(
          @env,
          env_dir: @env_dir,
          frontend_path: @frontend.path
        ).process_env
      end

      def sync_to_s3
        bucket = fetch_bucket_name
        abort "Error: Could not determine S3 bucket. Run `belt apply #{@env}` first." unless bucket

        dist = @frontend.dist_dir
        unless Dir.exist?(dist)
          abort "Error: Build output not found at #{dist}/. " \
                'Set `dist:` in config/frontends.yml if the app uses a non-default outDir.'
        end

        puts "☁️  Deploying to S3... (#{bucket})"

        dist_prefix = dist.end_with?('/') ? dist : "#{dist}/"

        # Hashed assets get immutable cache headers
        run!('aws', 's3', 'sync', dist_prefix, "s3://#{bucket}", '--delete',
             '--size-only', '--cache-control', 'public, max-age=31536000, immutable',
             '--exclude', 'index.html')

        index = File.join(dist, 'index.html')
        abort "Error: #{index} not found after build." unless File.exist?(index)

        # index.html always revalidates
        run!('aws', 's3', 'cp', index, "s3://#{bucket}/index.html",
             '--cache-control', 'no-cache')
      end

      def invalidate_cloudfront
        dist_id = fetch_distribution_id
        unless dist_id
          puts '⚠️  No CloudFront distribution found (skipping cache invalidation)'
          return
        end

        puts '🔄 Invalidating CloudFront cache...'
        run!('aws', 'cloudfront', 'create-invalidation', '--distribution-id', dist_id, '--paths', '/*',
             out: File::NULL)
        puts '✅ CloudFront cache invalidated'
      end

      def fetch_bucket_name
        fetch_tf_output(@frontend.bucket_output)
      end

      def fetch_distribution_id
        if probe_distribution_output?
          id = fetch_tf_output(@frontend.distribution_output)
          return id if id
        end

        domain = fetch_tf_output(@frontend.cloudfront_domain_output) if @frontend.cloudfront_domain_output
        domain ||= domain_from_url(fetch_frontend_url)
        lookup_distribution_id(domain)
      end

      # Belt-generated terraform exports `{name}_frontend_distribution_id`.
      # Stowzilla-style configs only export a CloudFront domain — skip the
      # inferred ID output so terraform doesn't print "output not found".
      def probe_distribution_output?
        @frontend.distribution_output_explicit? || @frontend.cloudfront_domain_output.to_s.empty?
      end

      def fetch_frontend_url
        fetch_tf_output(@frontend.url_output)
      end

      def domain_from_url(url)
        return nil if url.nil? || url.empty?

        url.sub(%r{\Ahttps?://}i, '').split('/').first
      end

      # Stowzilla-style fallback: terraform may export a CloudFront domain
      # instead of a distribution ID.
      def lookup_distribution_id(domain)
        return nil if domain.nil? || domain.empty?

        query = "DistributionList.Items[?DomainName=='#{domain}'].Id"
        output, status = Open3.capture2(
          'aws', 'cloudfront', 'list-distributions',
          '--query', query, '--output', 'text',
          err: File::NULL
        )
        return nil unless status.success?

        value = output.strip
        value.empty? || value == 'None' ? nil : value.split(/\s+/).first
      rescue Errno::ENOENT
        nil
      end

      def fetch_tf_output(name)
        return nil if name.nil? || name.to_s.empty?
        return nil unless Dir.exist?(@env_dir)

        output, status = Open3.capture2(
          'terraform', 'output', '-raw', name,
          chdir: @env_dir,
          err: File::NULL
        )
        return nil unless status.success?

        value = output.strip
        value.empty? || value == 'null' ? nil : value
      rescue Errno::ENOENT
        nil
      end

      def run!(*args, **)
        env = args.first.is_a?(Hash) ? args.shift : {}
        return if system(env, *args, **)

        abort "\n✗ Command failed: #{args.shelljoin}"
      end
    end
  end
end
