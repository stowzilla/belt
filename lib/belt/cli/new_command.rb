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
        domain = nil

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
          when '--domain'
            i += 1
            domain = args[i]
          when /^--domain=/
            domain = arg.split('=', 2).last
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
          puts '  --domain DOMAIN                Custom domain (e.g., myapp.com)'
          puts '  --bucket BUCKET_NAME           S3 bucket for Terraform state'
          puts '  --state-bucket BUCKET_NAME     Alias for --bucket'
          puts '  --environments dev,prod        Comma-separated environments (default: dev,prod)'
          puts '                                 Use "none" to skip environment setup'
          exit 1
        end

        new(app_name, frontend: frontend, bucket: bucket, environments: environments, domain: domain).generate
      end

      def initialize(app_name, frontend: nil, bucket: nil, environments: nil, domain: nil)
        @app_name = app_name.gsub(/[^a-z0-9_-]/i, '_').downcase
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
        @frontend = frontend
        @bucket = bucket
        @domain = domain
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
        generate_module
        puts "  create  app skeleton"
        generate_environments
        generate_frontend if @frontend
        init_git
        run_bundle_install
        setup_state
        puts "\n✓ #{@app_name} created successfully!"
        print_next_steps
        enter_project!
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
          #{@app_name}/lambda/lib/routes
          #{@app_name}/lambda/config
          #{@app_name}/lambda/spec
          #{@app_name}/config/lambda
          #{@app_name}/infrastructure/modules/app
        ]
      end

      def files
        {
          'Gemfile.erb' => "#{@app_name}/Gemfile",
          'Rakefile.erb' => "#{@app_name}/Rakefile",
          'lambda/api.rb.erb' => "#{@app_name}/lambda/api.rb",
          'lambda/config/environment.rb.erb' => "#{@app_name}/lambda/config/environment.rb",
          'lambda/models/application_record.rb.erb' => "#{@app_name}/lambda/models/application_record.rb",
          'lambda/controllers/application_controller.rb.erb' =>
            "#{@app_name}/lambda/controllers/api/application_controller.rb",
          'lambda/lib/routes/routes.rb.erb' => "#{@app_name}/lambda/lib/routes/api_routes.rb",
          'config/routes.tf.rb.erb' => "#{@app_name}/config/routes.tf.rb",
          'config/schema.tf.rb.erb' => "#{@app_name}/config/schema.tf.rb",
          'config/lambda/api.yml.erb' => "#{@app_name}/config/lambda/api.yml",
          'README.md.erb' => "#{@app_name}/README.md",
          'AGENTS.md.erb' => "#{@app_name}/AGENTS.md",
          'gitignore.erb' => "#{@app_name}/.gitignore"
        }
      end

      def generate_module
        module_dir = "#{@app_name}/infrastructure/modules/app"
        module_template_dir = File.expand_path('../../templates/module', File.dirname(__FILE__))

        module_templates = {
          'main.tf.erb' => 'main.tf',
          'variables.tf.erb' => 'variables.tf',
          'outputs.tf.erb' => 'outputs.tf',
          'dns.tf.erb' => 'dns.tf'
        }

        module_templates.each do |template_name, dest_file|
          dest_path = File.join(module_dir, dest_file)
          template_path = File.join(module_template_dir, template_name)
          content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
          File.write(dest_path, content)
        end
      end

      def generate_environments
        return if @environments.empty?

        Dir.chdir(@app_name) do
          @environments.each do |env_name|
            Belt::CLI::EnvironmentCommand.new(env_name, quiet: true, domain: @domain).generate
          end
        end
        puts "  create  environments (#{@environments.join(', ')})"
      end

      def setup_state
        return if @environments.empty?

        Dir.chdir(@app_name) do
          # Shared bucket: one per AWS account, all belt apps share it.
          # Account ID suffix makes the name globally unique (S3 is a global namespace).
          if @bucket
            @resolved_bucket = @bucket
          elsif aws_configured?
            @resolved_bucket = "belt-terraform-state-#{@aws_account_id}"
          else
            @resolved_bucket = 'belt-terraform-state'
          end

          # Attempt to actually create the bucket if credentials are available
          if aws_configured?
            begin
              setup = Belt::CLI::SetupCommand.new(['--bucket', @resolved_bucket], quiet: true)
              setup.run_state_setup
              @resolved_bucket = setup.bucket_name
              @state_setup_succeeded = true
              puts "  ✓      state bucket #{@resolved_bucket}"
            rescue SystemExit
              puts '  ⚠      state bucket setup failed — run `belt setup state` to retry'
              @state_setup_succeeded = false
            end
          else
            if @aws_error&.include?('ForbiddenException') || @aws_error&.include?('AccessDenied')
              puts '  ⚠      AWS credentials found but access denied — check profile/role'
            else
              puts '  ⚠      AWS credentials not detected — skipped state bucket'
            end
            puts '         run `belt setup state` after aws sso login / AWS_PROFILE'
            @state_setup_succeeded = false
          end
        end
      end

      def aws_configured?
        output, status = Open3.capture2e('aws', 'sts', 'get-caller-identity')
        if status.success?
          data = begin
            JSON.parse(output)
          rescue StandardError
            {}
          end
          @aws_account_id = data['Account']
          true
        else
          @aws_error = output.strip
          false
        end
      end

      def create_dir(dir)
        FileUtils.mkdir_p(dir)
      end

      def create_file(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
      end

      def init_git
        Dir.chdir(@app_name) do
          system('git', 'init', '--quiet')
        end
        puts '  init    git'
      end

      def run_bundle_install
        Dir.chdir(@app_name) do
          success = system('bundle', 'install', '--quiet')
          if success
            puts '  ✓      bundle install'
          else
            puts '  ⚠      bundle install failed — run it manually after resolving issues'
          end
        end
      end

      def generate_frontend
        frontend_cmd = nil
        Dir.chdir(@app_name) do
          frontend_cmd = Belt::CLI::FrontendCommand.new(@frontend, quiet: true)
          frontend_cmd.generate
        end
        puts "  create  frontend (#{@frontend})"
        if frontend_cmd.npm_ok?
          puts '  ✓      npm dependencies'
        else
          puts '  ⚠      npm install failed — run `cd frontend && npm install`'
        end
      end

      def print_next_steps
        puts "\nNext steps:"
        unless @state_setup_succeeded
          puts '  # Configure AWS credentials (aws sso login / AWS_PROFILE)'
          puts '  belt setup state              # Create the S3 state bucket'
        end
        puts '  belt deploy                   # Deploy to AWS'
        puts '  belt server                   # Start local frontend server' if @frontend
        if @domain
          puts "\n  Custom domain: #{@domain}"
          puts "    prod  → #{@domain}"
          puts "    dev   → dev.#{@domain}"
          puts ''
          puts '  DNS setup (after first deploy):'
          puts '  ─────────────────────────────────────────────────────────────────'
          puts '  1. Run: terraform output name_servers'
          puts '     This prints the 4 NS records for your Route53 hosted zone.'
          puts ''
          puts '  2. Point your domain to those nameservers:'
          puts ''
          puts '     • Domain registered OUTSIDE AWS (GoDaddy, Namecheap, etc.):'
          puts '       Go to your registrar → DNS/Nameserver settings → replace the'
          puts '       default nameservers with the 4 values from step 1.'
          puts ''
          puts '     • Domain registered IN AWS (Route53 Registered Domains):'
          puts '       Go to Route53 → Registered Domains → your domain → Name servers'
          puts '       → Edit → paste the 4 values from step 1.'
          puts ''
          puts '  3. Wait for propagation (usually 5–30 min, can take up to 48h).'
          puts "     Verify: dig +short NS #{@domain}"
          puts '  ─────────────────────────────────────────────────────────────────'
        else
          puts "\n  To add a custom domain later, set `domain` in infrastructure/<env>/terraform.tfvars:"
          puts '    domain = "myapp.com"'
        end
      end

      def enter_project!
        project_path = File.expand_path(@app_name)

        # Don't exec into a subshell if:
        # - Not running interactively (CI, scripts, piped)
        # - User explicitly opted out
        unless $stdin.tty? && ENV['BELT_NO_CD'].nil?
          puts "\n  cd #{@app_name}"
          return
        end

        Dir.chdir(project_path)
        shell = ENV['SHELL'] || '/bin/bash'
        puts "\n  Entering #{@app_name}/...\n\n"
        exec(shell)
      end

      def s3_safe_name(name)
        name.to_s.downcase.tr('_', '-')
      end
    end
  end
end
