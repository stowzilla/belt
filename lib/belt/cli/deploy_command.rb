# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'env_resolver'
require_relative 'terraform_command'

module Belt
  module CLI
    class DeployCommand
      def self.run(args)
        # Handle `belt deploy frontend <env>` as before
        if args.first == 'frontend'
          args.shift
          Belt::CLI::FrontendDeployCommand.run(args)
          return
        end

        auto_approve = false
        rebuild = false
        filtered_args = []

        args.each do |arg|
          case arg
          when '--auto', '--yes', '-y'
            auto_approve = true
          when '--rebuild'
            rebuild = true
          when '-h', '--help'
            puts help_text
            exit 0
          else
            filtered_args << arg
          end
        end

        env = EnvResolver.resolve(filtered_args)

        # Default to the first available environment when none specified
        if env.nil?
          available = TerraformCommand.list_environments
          if available.any?
            env = available.first
          else
            puts 'Usage: belt deploy [environment] [options]'
            puts "\nDefaults to BELT_ENV or the first available environment."
            puts "\nOptions:"
            puts '  --auto, --yes, -y    Skip confirmation prompt (auto-approve)'
            puts '  --rebuild            Rebuild and push Lambda code directly (bypasses Terraform)'
            puts '  -h, --help           Show this help'
            puts "\nExamples:"
            puts '  belt deploy                # Deploy dev (or BELT_ENV)'
            puts '  belt deploy prod           # Deploy to prod'
            puts '  belt deploy dev --auto     # Deploy without confirmation'
            puts '  belt deploy --rebuild      # Fast code push (no infra changes)'
            puts '  belt deploy frontend dev   # Deploy frontend only'
            puts "\nNo environments found. Run `belt generate environment dev` first."
            exit 1
          end
        end

        if rebuild
          new(env, auto_approve: auto_approve, extra_args: filtered_args).run_rebuild
        else
          new(env, auto_approve: auto_approve, extra_args: filtered_args).run
        end
      end

      def self.help_text
        <<~HELP
          Deploy your Belt application to AWS.

          Usage: belt deploy [environment] [options]
                 belt deploy frontend <environment>

          This runs the full deployment lifecycle:
            1. Ensure Gemfile.lock is consistent (fix stale PATH refs)
            2. terraform init    (initialize providers/modules)
            3. terraform plan    (preview changes)
            4. Prompt for confirmation (unless --auto)
            5. terraform apply   (deploy changes)

          Options:
            --auto, --yes, -y    Skip confirmation prompt (auto-approve)
            --rebuild            Rebuild and push Lambda code directly (bypasses Terraform).
                                 Much faster for code-only changes — packages gems via Docker,
                                 zips, and pushes with `aws lambda update-function-code`.
            -h, --help           Show this help

          Environment:
            Defaults to BELT_ENV if set, otherwise the first available environment.

          Examples:
            belt deploy                # Deploy dev (or BELT_ENV)
            belt deploy prod           # Deploy to prod
            belt deploy dev --auto     # Deploy without confirmation (CI mode)
            belt deploy --rebuild      # Fast code push to dev (no infra changes)
            belt deploy prod --rebuild # Fast code push to prod
            belt deploy frontend dev   # Deploy frontend assets only
        HELP
      end

      def initialize(env, auto_approve: false, extra_args: [])
        @env = env
        @auto_approve = auto_approve
        @extra_args = extra_args
        @infra_dir = TerraformCommand.find_infrastructure_dir
        @project_root = find_project_root
      end

      def run
        validate!
        env_dir = File.join(@infra_dir, @env)

        puts "belt → deploying #{@env} (in #{env_dir}/)\n\n"

        ensure_lockfile_consistent!

        Dir.chdir(env_dir) do
          run_init
          run_plan
          return unless confirm_apply
          run_apply
        end

        puts "\n✅ Deployed #{@env} successfully!"
        print_outputs(env_dir)
        puts "\n   Run `belt server` to view your app locally (auto-connects to the deployed API)."
      end

      def run_rebuild
        validate!
        validate_aws!

        puts "belt → rebuilding Lambda for #{@env}\n\n"

        lambda_dir = find_lambda_dir
        abort 'Error: Cannot find lambda/ directory.' unless lambda_dir

        function_name = find_lambda_function_name
        abort 'Error: Cannot determine Lambda function name from Terraform state.' unless function_name

        ensure_lockfile_consistent!
        generate_routes(lambda_dir)
        build_and_deploy(lambda_dir, function_name)
      end

      private

      def find_project_root
        # Walk up from infra dir to find project root (where Gemfile lives)
        dir = @infra_dir ? File.dirname(@infra_dir) : Dir.pwd
        while dir != '/'
          return dir if File.exist?(File.join(dir, 'Gemfile'))
          dir = File.dirname(dir)
        end
        Dir.pwd
      end

      def find_lambda_dir
        candidates = [
          File.join(@project_root, 'lambda'),
          File.join(Dir.pwd, 'lambda')
        ]
        candidates.find { |d| Dir.exist?(d) }
      end

      def validate!
        unless @infra_dir
          abort "Error: No infrastructure/ directory found.\n" \
                "Run `belt generate environment #{@env}` first."
        end

        env_dir = File.join(@infra_dir, @env)
        return if Dir.exist?(env_dir)

        abort "Error: Environment '#{@env}' not found at #{env_dir}/.\n\n" \
              "Available environments:\n#{TerraformCommand.list_environments.map { |e| "  #{e}" }.join("\n")}\n\n" \
              "Create it with: belt generate environment #{@env}"
      end

      def validate_aws!
        stdout, status = Open3.capture2('aws', 'sts', 'get-caller-identity', '--output', 'json')
        unless status.success?
          abort "Error: AWS credentials not available.\n" \
                "Run `aws sso login` or configure AWS_PROFILE."
        end
        @aws_account = JSON.parse(stdout)['Account'] rescue nil
      end

      # Ensure Gemfile.lock doesn't have stale PATH references that will break
      # the Docker-based gem build. If the Gemfile no longer uses `path:` but the
      # lockfile still references a PATH source, refresh the lock.
      def ensure_lockfile_consistent!
        gemfile = File.join(@project_root, 'Gemfile')
        lockfile = File.join(@project_root, 'Gemfile.lock')
        return unless File.exist?(gemfile) && File.exist?(lockfile)

        gemfile_content = File.read(gemfile)
        lockfile_content = File.read(lockfile)

        # Find gems that are PATH-sourced in the lockfile but NOT path-sourced in the Gemfile
        stale_path_gems = detect_stale_path_gems(gemfile_content, lockfile_content)
        return if stale_path_gems.empty?

        puts "  🔧 Fixing stale Gemfile.lock (#{stale_path_gems.join(', ')} referenced as PATH but Gemfile uses RubyGems)"
        Dir.chdir(@project_root) do
          success = system('bundle', 'lock', '--update', *stale_path_gems)
          unless success
            puts "  ⚠ `bundle lock --update #{stale_path_gems.join(' ')}` failed — trying full bundle update"
            system('bundle', 'update', *stale_path_gems)
          end
        end
        puts ''
      end

      def detect_stale_path_gems(gemfile_content, lockfile_content)
        stale = []

        # Parse PATH sections from lockfile
        # Format:
        #   PATH
        #     remote: ../something
        #     specs:
        #       gem_name (version)
        lockfile_content.scan(/^PATH\n\s+remote:.*?\n\s+specs:\n((?:\s{4}\S.*\n?)+)/m).each do |match|
          match[0].scan(/^\s{4}(\S+)\s/).each do |gem_match|
            gem_name = gem_match[0]
            # Check if the Gemfile still uses path: for this gem
            # Match patterns like: gem 'name', path: ... or gem "name", path: ...
            has_path_in_gemfile = gemfile_content.match?(/gem\s+['"]#{Regexp.escape(gem_name)}['"].*path:/)
            stale << gem_name unless has_path_in_gemfile
          end
        end

        stale
      end

      def find_lambda_function_name
        env_dir = File.join(@infra_dir, @env)
        return nil unless Dir.exist?(File.join(env_dir, '.terraform'))

        # Get function name from terraform state
        Dir.chdir(env_dir) do
          output, status = Open3.capture2('terraform', 'output', '-json')
          return nil unless status.success?

          data = JSON.parse(output) rescue {}

          # Try lambda_functions output first
          if data['lambda_functions']
            funcs = data['lambda_functions']['value']
            if funcs.is_a?(Hash) && funcs.any?
              return funcs.values.first # ARN — we need just the function name
            end
          end

          # Fallback: parse from terraform state directly
          state_output, state_status = Open3.capture2('terraform', 'state', 'show', 'conveyor_belt.main')
          return nil unless state_status.success?

          # Look for lambda function names in state
          state_output.match(/function_name\s*=\s*"([^"]+)"/)&.captures&.first
        end
      end

      def generate_routes(lambda_dir)
        routes_dir = File.join(lambda_dir, 'lib', 'routes')
        return unless Dir.exist?(routes_dir)

        puts '  🗺️  Regenerating route manifests...'
        success = system('belt', 'routes', '--namespace', 'all', '--output-dir', routes_dir)
        if success
          puts '  ✅ Routes updated'
        else
          puts '  ⚠ Route generation failed — using existing manifests'
        end
        puts ''
      end

      def build_and_deploy(lambda_dir, function_identifier)
        # Extract function name from ARN if needed
        function_name = if function_identifier.include?(':')
                          function_identifier.split(':').last
                        else
                          function_identifier
                        end

        build_dir = Dir.mktmpdir('belt-rebuild-')

        begin
          puts '  📦 Building Lambda package...'
          assemble_package(lambda_dir, build_dir)
          build_gems(build_dir)
          zip_file = create_zip(build_dir)

          puts '  🚀 Deploying to AWS...'
          deploy_to_lambda(function_name, zip_file)

          puts "\n✅ Lambda #{function_name} rebuilt and deployed!"
          puts ''
          puts '  📋 View logs:'
          puts "    aws logs tail /aws/lambda/#{function_name} --follow"
        ensure
          FileUtils.rm_rf(build_dir)
        end
      end

      def assemble_package(lambda_dir, build_dir)
        # Copy handler file(s) — .rb files at root of lambda/
        Dir.glob(File.join(lambda_dir, '*.rb')).each do |f|
          FileUtils.cp(f, build_dir)
        end

        # Copy shared directories
        %w[controllers models lib helpers templates serializers jobs config].each do |dir|
          src = File.join(lambda_dir, dir)
          FileUtils.cp_r(src, File.join(build_dir, dir)) if Dir.exist?(src)
        end

        # Copy Gemfile from project root
        gemfile = File.join(@project_root, 'Gemfile')
        lockfile = File.join(@project_root, 'Gemfile.lock')
        FileUtils.cp(gemfile, build_dir) if File.exist?(gemfile)
        FileUtils.cp(lockfile, build_dir) if File.exist?(lockfile)

        puts '    📁 Copied handlers, controllers, models, lib, config'
      end

      def build_gems(build_dir)
        puts '    🐳 Building gems in Docker (Lambda-compatible)...'

        docker_cmd = [
          'docker', 'run', '--rm',
          '--platform', 'linux/amd64',
          '-v', "#{build_dir}:/var/task",
          '-w', '/var/task',
          'public.ecr.aws/sam/build-ruby3.4:latest-x86_64',
          '/bin/bash', '-c',
          "bundle config set --local path 'vendor/bundle' && " \
          "bundle config set --local without 'development test' && " \
          'bundle config set silence_root_warning 1 && ' \
          'bundle install --jobs 4 && ' \
          'bundle clean --force'
        ]

        output, status = Open3.capture2e(*docker_cmd)
        unless status.success?
          puts output
          abort "\n✗ Gem build failed. Check Docker is running and the Gemfile is valid."
        end

        # Strip fat from vendor bundle
        strip_vendor_fat(build_dir)
        puts '    ✅ Gems installed'
      end

      def strip_vendor_fat(build_dir)
        vendor_dir = File.join(build_dir, 'vendor')
        return unless Dir.exist?(vendor_dir)

        # Remove docs, tests, and non-runtime files from gems
        Dir.glob(File.join(vendor_dir, 'bundle/ruby/*/gems/*/')).each do |gem_dir|
          %w[spec test tests doc docs examples benchmarks].each do |fat_dir|
            FileUtils.rm_rf(File.join(gem_dir, fat_dir))
          end
        end

        # Remove non-essential files
        exts = %w[*.md *.rdoc *.txt *.c *.h *.o Makefile *.log CHANGELOG* HISTORY* LICENSE* README* .gitignore .travis.yml .rubocop.yml Rakefile]
        exts.each do |pattern|
          Dir.glob(File.join(vendor_dir, "**", pattern)).each do |f|
            File.delete(f) if File.file?(f)
          end
        end

        # Strip debug symbols from native extensions
        Dir.glob(File.join(vendor_dir, '**/*.so')).each do |so_file|
          system('strip', '--strip-debug', so_file, err: File::NULL, out: File::NULL)
        end
      end

      def create_zip(build_dir)
        zip_file = File.join(Dir.tmpdir, "belt-lambda-#{@env}-#{Time.now.to_i}.zip")

        Dir.chdir(build_dir) do
          output, status = Open3.capture2e('zip', '-qr', zip_file, '.')
          unless status.success?
            puts output
            abort "\n✗ Failed to create ZIP"
          end
        end

        size_mb = (File.size(zip_file) / 1024.0 / 1024.0).round(1)
        puts "    🗜️  Package: #{size_mb}MB"
        zip_file
      end

      def deploy_to_lambda(function_name, zip_file)
        _output, status = Open3.capture2(
          'aws', 'lambda', 'update-function-code',
          '--function-name', function_name,
          '--zip-file', "fileb://#{zip_file}",
          '--output', 'json'
        )

        File.delete(zip_file) if File.exist?(zip_file)

        unless status.success?
          abort "\n✗ Failed to update Lambda function code.\n" \
                "  Function: #{function_name}\n" \
                "  Check that the function exists and you have permissions."
        end

        # Wait for update to complete
        print '    Waiting for Lambda to be ready...'
        30.times do
          sleep 1
          state_output, = Open3.capture2(
            'aws', 'lambda', 'get-function',
            '--function-name', function_name,
            '--query', 'Configuration.LastUpdateStatus',
            '--output', 'text'
          )
          case state_output.strip
          when 'Successful'
            puts ' ✅'
            return
          when 'Failed'
            puts ' ✗'
            abort '    Lambda update failed. Check CloudWatch logs.'
          end
          print '.'
        end
        puts ' (timed out waiting, but code was pushed)'
      end

      def run_init
        puts '━━━ terraform init ━━━'
        success = system('terraform', 'init')
        abort "\n✗ terraform init failed" unless success
        puts ''
      end

      def run_plan
        puts '━━━ terraform plan ━━━'
        success = system('terraform', 'plan', '-out=tfplan', *@extra_args)
        abort "\n✗ terraform plan failed" unless success
        puts ''
      end

      def confirm_apply
        return true if @auto_approve

        if @env == 'prod' || @env == 'production'
          print "⚠️  You are about to deploy to \e[1;31m#{@env}\e[0m. Continue? [y/N] "
        else
          print "Apply these changes to #{@env}? [y/N] "
        end

        response = $stdin.gets
        return true if response&.strip&.downcase&.start_with?('y')

        puts 'Cancelled.'
        cleanup_plan
        false
      end

      def run_apply
        puts '━━━ terraform apply ━━━'
        success = system('terraform', 'apply', 'tfplan')
        cleanup_plan
        abort "\n✗ terraform apply failed" unless success
      end

      def cleanup_plan
        File.delete('tfplan') if File.exist?('tfplan')
      end

      def print_outputs(env_dir)
        Dir.chdir(env_dir) do
          output = `terraform output 2>/dev/null`.strip
          return if output.empty?

          puts "\nOutputs:"
          output.each_line do |line|
            puts "  #{line}"
          end
        end
      end
    end
  end
end
