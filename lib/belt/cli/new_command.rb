# frozen_string_literal: true

require 'fileutils'
require 'erb'
require 'json'
require 'open3'
require_relative 'setup_command'

module Belt
  module CLI
    class NewCommand
      TEMPLATE_DIR = File.expand_path('../../templates/new_app', __dir__)
      DEFAULT_ENVIRONMENTS = %w[dev prod].freeze

      def self.run(args)
        app_name = nil
        frontend = nil
        bucket = nil
        environments = nil

        i = 0
        while i < args.length
          arg = args[i]
          case arg
          when '--frontend'
            if arg.include?('=')
              frontend = arg.split('=', 2).last
            else
              i += 1
              frontend = args[i]
            end
          when /^--frontend=/
            frontend = arg.split('=', 2).last
          when '--bucket', '--state-bucket'
            i += 1
            bucket = args[i]
          when /^--bucket=/
            bucket = arg.split('=', 2).last
          when /^--state-bucket=/
            bucket = arg.split('=', 2).last
          when '--environments'
            i += 1
            environments = args[i]
          when /^--environments=/
            environments = arg.split('=', 2).last
          else
            app_name ||= arg unless arg.start_with?('-')
          end
          i += 1
        end

        if app_name.nil? || app_name.empty?
          puts 'Usage: belt new <app_name> [options]'
          puts ''
          puts 'Options:'
          puts '  --frontend react|vue|svelte    Set up frontend framework'
          puts '  --bucket BUCKET_NAME           S3 bucket for Terraform state'
          puts '  --state-bucket BUCKET_NAME     Alias for --bucket'
          puts '  --environments dev,prod        Comma-separated environments (default: dev,prod)'
          puts '                                 Use "none" to skip environment setup'
          exit 1
        end

        new(app_name, frontend: frontend, bucket: bucket, environments: environments).generate
      end

      def initialize(app_name, frontend: nil, bucket: nil, environments: nil)
        @app_name = app_name.gsub(/[^a-z0-9_-]/i, '_').downcase
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
        @frontend = frontend
        @bucket = bucket
        @environments = parse_environments(environments)
        @resolved_bucket = nil
        @state_setup_succeeded = false
      end

      def generate
        if Dir.exist?(@app_name)
          puts "Directory '#{@app_name}' already exists."
          exit 1
        end

        puts "Creating new Belt application: #{@app_name}"
        create_structure
        generate_environments
        generate_frontend if @frontend
        init_git
        run_bundle_install
        setup_state
        puts "\n✓ #{@app_name} created successfully!"
        print_next_steps
      end

      private

      def parse_environments(env_string)
        return DEFAULT_ENVIRONMENTS if env_string.nil? || env_string.empty?
        return [] if env_string.downcase == 'none'

        env_string.split(',').map(&:strip).reject(&:empty?)
      end

      def create_structure
        directories.each { |dir| create_dir(dir) }
        files.each { |src, dest| create_file(src, dest) }
      end

      def directories
        %W[
          #{@app_name}/lambda/controllers/api
          #{@app_name}/lambda/models
          #{@app_name}/lambda/models/concerns
          #{@app_name}/lambda/lib/routes
          #{@app_name}/lambda/config
          #{@app_name}/lambda/spec
          #{@app_name}/infrastructure
        ]
      end

      def files
        {
          'Gemfile.erb' => "#{@app_name}/Gemfile",
          'Rakefile.erb' => "#{@app_name}/Rakefile",
          'lambda/api.rb.erb' => "#{@app_name}/lambda/api.rb",
          'lambda/config/environment.rb.erb' => "#{@app_name}/lambda/config/environment.rb",
          'lambda/models/application_record.rb.erb' => "#{@app_name}/lambda/models/application_record.rb",
          'lambda/models/concerns/timestampable.rb.erb' => "#{@app_name}/lambda/models/concerns/timestampable.rb",
          'lambda/controllers/application_controller.rb.erb' =>
            "#{@app_name}/lambda/controllers/api/application_controller.rb",
          'lambda/lib/routes/routes.rb.erb' => "#{@app_name}/lambda/lib/routes/api_routes.rb",
          'infrastructure/routes.tf.rb.erb' => "#{@app_name}/infrastructure/routes.tf.rb",
          'infrastructure/schema.tf.rb.erb' => "#{@app_name}/infrastructure/schema.tf.rb",
          'README.md.erb' => "#{@app_name}/README.md",
          'AGENTS.md.erb' => "#{@app_name}/AGENTS.md",
          'gitignore.erb' => "#{@app_name}/.gitignore"
        }
      end

      def generate_environments
        return if @environments.empty?

        Dir.chdir(@app_name) do
          @environments.each do |env_name|
            Belt::CLI::EnvironmentCommand.new(env_name, quiet: true).generate
          end
        end
      end

      def setup_state
        return if @environments.empty?

        Dir.chdir(@app_name) do
          # Resolve bucket name — include account ID + region if AWS credentials are available
          if @bucket
            @resolved_bucket = @bucket
          elsif aws_configured?
            region = detect_region
            @resolved_bucket = s3_safe_name("#{@app_name}-terraform-state-#{@aws_account_id}-#{region}")
          else
            @resolved_bucket = s3_safe_name("#{@app_name}-terraform-state")
          end

          # Update backend.tf files with the resolved bucket name
          @environments.each do |env_name|
            backend_file = "infrastructure/#{env_name}/backend.tf"
            next unless File.exist?(backend_file)

            content = File.read(backend_file)
            updated = content.gsub(/bucket\s*=\s*"[^"]+"/, "bucket  = \"#{@resolved_bucket}\"")
            File.write(backend_file, updated) if updated != content
          end

          # Attempt to actually create the bucket if credentials are available
          if @aws_account_id
            puts "\n  Setting up Terraform state bucket..."
            begin
              Belt::CLI::SetupCommand.new(["--bucket", @resolved_bucket]).run_state_setup
              @state_setup_succeeded = true
            rescue SystemExit
              puts '  ⚠ State bucket setup encountered an issue — run `belt setup state` to retry.'
              @state_setup_succeeded = false
            end
          else
            puts "\n  State bucket: #{@resolved_bucket}"
            if @aws_error&.include?('ForbiddenException') || @aws_error&.include?('AccessDenied')
              puts "  ⚠ AWS credentials found but access denied — check your profile/role configuration."
              puts "    #{@aws_error}" if @aws_error
            else
              puts '  ⚠ AWS credentials not detected — skipping state bucket creation.'
            end
            puts '  Run `belt setup state` after configuring credentials (aws sso login / AWS_PROFILE).'
            @state_setup_succeeded = false
          end
        end
      end

      def detect_region
        Dir.glob('infrastructure/*/backend.tf').each do |f|
          match = File.read(f).match(/region\s*=\s*"([^"]+)"/)
          return match[1] if match
        end
        'us-east-1'
      end

      def aws_configured?
        output, status = Open3.capture2e('aws', 'sts', 'get-caller-identity')
        if status.success?
          data = JSON.parse(output) rescue {}
          @aws_account_id = data['Account']
          true
        else
          @aws_error = output.strip
          false
        end
      end

      def create_dir(dir)
        FileUtils.mkdir_p(dir)
        puts "  create  #{dir}/"
      end

      def create_file(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
        puts "  create  #{dest_path}"
      end

      def init_git
        Dir.chdir(@app_name) do
          system('git', 'init', '--quiet')
        end
        puts "  init    #{@app_name}/.git/"
      end

      def run_bundle_install
        Dir.chdir(@app_name) do
          puts "\n  Running bundle install..."
          success = system('bundle', 'install', '--quiet')
          if success
            puts '  ✓ Bundle installed'
          else
            puts '  ⚠ bundle install failed — run it manually after resolving issues.'
          end
        end
      end

      def generate_frontend
        Dir.chdir(@app_name) do
          Belt::CLI::FrontendCommand.new(@frontend).generate
        end
      end

      def print_next_steps
        puts "\nNext steps:"
        puts "  cd #{@app_name}"
        unless @state_setup_succeeded
          puts '  # Configure AWS credentials (aws sso login / AWS_PROFILE)'
          puts '  belt setup state              # Create the S3 state bucket'
        end
        puts '  belt deploy                   # Deploy to AWS'
        puts '  belt server                   # Start local frontend server' if @frontend
      end

      def s3_safe_name(name)
        name.to_s.downcase.tr('_', '-')
      end
    end
  end
end
