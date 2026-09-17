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
        env_config = EnvironmentConfig.load(@env, infra_dir: @infra_dir)
        env_config.apply!
        puts "  🔑 Using AWS profile: #{env_config.aws_profile}" if env_config.aws_profile?
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
        abort(bucket_lookup_failure_message) unless bucket

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

      # The bucket output came back nil. Figure out *why* instead of always
      # blaming a missing apply. `terraform output` swallows its own stderr in
      # fetch_tf_output, so re-run it once with stderr captured and translate the
      # failure into something actionable:
      #   - no state at all      → env was never applied (or wrong dir)
      #   - credential/SSO error → the AWS profile/session is the problem
      #   - output just missing  → applied, but this frontend's output isn't there
      def bucket_lookup_failure_message
        _out, err, _status = Open3.capture3(
          'terraform', 'output', '-raw', @frontend.bucket_output.to_s,
          chdir: @env_dir
        )
        stderr = err.to_s.strip
        first_line = stderr.lines.first&.strip

        if credential_error?(stderr)
          [
            "Error: Could not reach Terraform state for '#{@env}' — AWS credentials failed.",
            "  #{first_line}",
            "  Check the aws_profile in infrastructure/#{@env}/belt.rb and that its SSO " \
            'session is active (`aws sso login --profile <profile>`).'
          ].join("\n")
        elsif no_state?(stderr) || !state_present?
          [
            "Error: No Terraform state for '#{@env}' yet — nothing to deploy the frontend against.",
            "  Run `belt deploy #{@env}` to provision the backend first, then retry the frontend deploy."
          ].join("\n")
        else
          lines = [
            "Error: Terraform output `#{@frontend.bucket_output}` not found for '#{@env}'.",
            "  The backend is applied but this frontend's bucket output is missing. " \
            'Check config/frontends.yml and that the frontend module is included in terraform.'
          ]
          lines << "  terraform: #{first_line}" if first_line
          lines.join("\n")
        end
      rescue Errno::ENOENT
        "Error: `terraform` not found on PATH. Install Terraform, then run `belt deploy #{@env}` first."
      end

      def credential_error?(stderr)
        stderr.match?(/credential|sso|token|AccessDenied|not authorized|403/i)
      end

      def no_state?(stderr)
        stderr.match?(
          /No state file|no outputs|state.*not.*found|Backend initialization required|not been initialized/i
        )
      end

      # A locally-applied env has a terraform.tfstate; a remote-backed one has an
      # initialized .terraform dir. Absence of both means it was never applied here.
      def state_present?
        File.exist?(File.join(@env_dir, 'terraform.tfstate')) ||
          Dir.exist?(File.join(@env_dir, '.terraform'))
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
