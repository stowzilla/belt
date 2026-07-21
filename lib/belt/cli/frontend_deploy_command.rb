# frozen_string_literal: true

require 'shellwords'
require 'open3'
require_relative 'app_detection'
require_relative 'env_resolver'
require_relative 'frontend_env_map'

module Belt
  module CLI
    class FrontendDeployCommand
      include AppDetection

      def self.run(args)
        env = EnvResolver.resolve(args)

        if env.nil?
          puts 'Usage: belt deploy frontend <environment>'
          puts "\nBuilds the frontend app and deploys to S3 + invalidates CloudFront."
          puts 'You can also set BELT_ENV to skip the environment argument.'
          puts "\nExamples:"
          puts '  belt deploy frontend wups'
          puts '  belt deploy frontend dev01'
          puts '  BELT_ENV=wups belt deploy frontend'
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
        build_frontend
        sync_to_s3
        invalidate_cloudfront
        url = fetch_frontend_url
        puts "\n✅ Frontend deployed to #{@env}!"
        puts "   #{url}" if url
      end

      private

      def validate!
        unless Dir.exist?('frontend')
          abort 'Error: No frontend/ directory found. Run `belt generate frontend react` first.'
        end
        return if File.exist?('frontend/package.json')

        abort 'Error: frontend/package.json not found.'
      end

      def build_frontend
        puts '📦 Installing dependencies...'
        install_cmd = File.exist?('frontend/package-lock.json') ? %w[npm ci] : %w[npm install]
        run!(*install_cmd, chdir: 'frontend')

        puts '🏗️  Building frontend...'
        env = frontend_build_env
        puts "   Injecting env: #{env.keys.sort.join(', ')}" if env.any?
        run!(env, 'npm', 'run', 'build', chdir: 'frontend')
      end

      # Resolve build env from frontend/env.yml map (or default VITE_API_URL ← api_url).
      def frontend_build_env
        FrontendEnvMap.new(@env, env_dir: @env_dir).process_env
      end

      def sync_to_s3
        bucket = fetch_bucket_name
        abort "Error: Could not determine S3 bucket. Run `belt apply #{@env}` first." unless bucket

        puts "☁️  Deploying to S3... (#{bucket})"

        # Hashed assets get immutable cache headers
        run!('aws', 's3', 'sync', 'frontend/dist/', "s3://#{bucket}", '--delete',
             '--size-only', '--cache-control', 'public, max-age=31536000, immutable',
             '--exclude', 'index.html')

        # index.html always revalidates
        run!('aws', 's3', 'cp', 'frontend/dist/index.html', "s3://#{bucket}/index.html",
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
        fetch_tf_output('frontend_bucket_name')
      end

      def fetch_distribution_id
        fetch_tf_output('frontend_distribution_id')
      end

      def fetch_frontend_url
        fetch_tf_output('frontend_url')
      end

      def fetch_tf_output(name)
        output, status = Open3.capture2('terraform', 'output', '-raw', name, chdir: @env_dir)
        return nil unless status.success?

        value = output.strip
        value.empty? || value == 'null' ? nil : value
      end

      def run!(*args, **)
        env = args.first.is_a?(Hash) ? args.shift : {}
        return if system(env, *args, **)

        abort "\n✗ Command failed: #{args.shelljoin}"
      end
    end
  end
end
