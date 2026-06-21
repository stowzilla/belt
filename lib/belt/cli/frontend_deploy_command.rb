# frozen_string_literal: true

module Belt
  module CLI
    class FrontendDeployCommand
      def self.run(args)
        env = args.shift

        if env.nil? || env.start_with?('-')
          puts "Usage: belt deploy frontend <environment>"
          puts "\nBuilds the frontend app and deploys to S3 + invalidates CloudFront."
          puts "\nExamples:"
          puts "  belt deploy frontend wups"
          puts "  belt deploy frontend dev01"
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
        puts "\n✅ Frontend deployed to #{@env}!"
      end

      private

      def validate!
        unless Dir.exist?('frontend')
          abort "Error: No frontend/ directory found. Run `belt generate frontend react` first."
        end
        unless File.exist?('frontend/package.json')
          abort "Error: frontend/package.json not found."
        end
      end

      def build_frontend
        puts "📦 Installing dependencies..."
        run!("cd frontend && npm ci")

        puts "🏗️  Building frontend..."
        # Pass API URL from terraform output if available
        api_url = fetch_api_url
        env_vars = api_url ? "VITE_API_URL=#{api_url} " : ""
        run!("cd frontend && #{env_vars}npm run build")
      end

      def sync_to_s3
        bucket = fetch_bucket_name
        abort "Error: Could not determine S3 bucket. Run `belt apply #{@env}` first." unless bucket

        puts "☁️  Deploying to S3... (#{bucket})"

        # Hashed assets get immutable cache headers
        run!("aws s3 sync frontend/dist/ s3://#{bucket} --delete " \
             "--size-only --cache-control 'public, max-age=31536000, immutable' " \
             "--exclude 'index.html'")

        # index.html always revalidates
        run!("aws s3 cp frontend/dist/index.html s3://#{bucket}/index.html " \
             "--cache-control 'no-cache'")
      end

      def invalidate_cloudfront
        dist_id = fetch_distribution_id
        unless dist_id
          puts "⚠️  No CloudFront distribution found (skipping cache invalidation)"
          return
        end

        puts "🔄 Invalidating CloudFront cache..."
        run!("aws cloudfront create-invalidation --distribution-id #{dist_id} --paths '/*' > /dev/null 2>&1")
        puts "✅ CloudFront cache invalidated"
      end

      def fetch_api_url
        output = `cd #{@env_dir} && terraform output -raw api_url 2>/dev/null`
        $?.success? && !output.strip.empty? ? output.strip : nil
      end

      def fetch_bucket_name
        output = `cd #{@env_dir} && terraform output -raw frontend_bucket_name 2>/dev/null`
        $?.success? && !output.strip.empty? ? output.strip : nil
      end

      def fetch_distribution_id
        output = `cd #{@env_dir} && terraform output -raw frontend_distribution_id 2>/dev/null`
        $?.success? && !output.strip.empty? ? output.strip : nil
      end

      def run!(cmd)
        unless system(cmd)
          abort "\n✗ Command failed: #{cmd}"
        end
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
