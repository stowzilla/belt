# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'env_resolver'
require_relative 'terraform_command'
require_relative 'backup_config'
require_relative 'backup_runner'
require_relative 'environment_config'
require_relative 'path_gem_materializer'

module Belt
  module CLI
    class DeployCommand
      DEFAULT_DOCKER_BUILD_IMAGE = 'public.ecr.aws/sam/build-ruby3.4:latest-x86_64'
      def self.run(args)
        # Handle `belt deploy frontend <env>` as before
        if args.first == 'frontend'
          args.shift
          Belt::CLI::FrontendDeployCommand.run(args)
          return
        end

        auto_approve = false
        rebuild = false
        skip_backup = false
        backup_only = false
        filtered_args = []

        args.each do |arg|
          case arg
          when '--auto', '--yes', '-y'
            auto_approve = true
          when '--rebuild'
            rebuild = true
          when '--skip-backup', '--no-backup'
            skip_backup = true
          when '--backup-only'
            backup_only = true
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

        if backup_only
          new(env, auto_approve: auto_approve, skip_backup: false, extra_args: filtered_args).run_backup_only
        elsif rebuild
          new(env, auto_approve: auto_approve, skip_backup: skip_backup, extra_args: filtered_args).run_rebuild
        else
          new(env, auto_approve: auto_approve, skip_backup: skip_backup, extra_args: filtered_args).run
        end
      end

      def self.help_text
        <<~HELP
          Deploy your Belt application to AWS.

          Usage: belt deploy [environment] [options]
                 belt deploy frontend <environment>

          This runs the full deployment lifecycle:
            1. Ensure Gemfile.lock is consistent (fix stale PATH refs)
            2. Regenerate route manifests
            3. Run pre-deploy backups (if configured in belt.rb)
            4. terraform init    (initialize providers/modules)
            5. terraform plan    (preview changes)
            6. Prompt for confirmation (unless --auto)
            7. terraform apply   (deploy changes)

          Options:
            --auto, --yes, -y    Skip confirmation prompt (auto-approve)
            --rebuild            Rebuild and push Lambda code directly (bypasses Terraform).
                                 Much faster for code-only changes — packages gems via Docker,
                                 zips, and pushes with `aws lambda update-function-code`.
            --skip-backup        Skip pre-deploy backup phase
            --no-backup          Alias for --skip-backup
            --backup-only        Run backups only, do not deploy
            -h, --help           Show this help

          Environment:
            Defaults to BELT_ENV if set, otherwise the first available environment.

          Backup Configuration:
            Create `infrastructure/<env>/belt.rb` to configure backups:

              Belt.configure do |config|
                config.backups do
                  dynamodb :all
                  cognito :users, :pool_config
                  s3 :legal_documents
                  retention snapshots: 90, cognito: 10, s3: 10
                end
              end

          Examples:
            belt deploy                # Deploy dev (or BELT_ENV)
            belt deploy prod           # Deploy to prod
            belt deploy dev --auto     # Deploy without confirmation (CI mode)
            belt deploy --rebuild      # Fast code push to dev (no infra changes)
            belt deploy prod --rebuild # Fast code push to prod
            belt deploy prod --skip-backup  # Skip backups for this deploy
            belt deploy prod --backup-only  # Run backups without deploying
            belt deploy frontend dev   # Deploy frontend assets only
        HELP
      end

      def initialize(env, auto_approve: false, skip_backup: false, extra_args: [])
        @env = env
        @auto_approve = auto_approve
        @skip_backup = skip_backup
        @extra_args = extra_args
        @infra_dir = TerraformCommand.find_infrastructure_dir
        @project_root = find_project_root
      end

      def run
        validate!
        run_preflight_checks!
        env_dir = File.join(@infra_dir, @env)

        load_and_apply_env_config!

        puts "belt → deploying #{@env} (in #{env_dir}/)\n\n"

        ensure_lockfile_consistent!
        warn_active_path_gems!
        generate_routes_if_needed
        run_backups unless @skip_backup

        Dir.chdir(env_dir) do
          run_init
          run_plan
          return unless confirm_apply?

          run_apply
        end

        puts "\n✅ Deployed #{@env} successfully!"
        print_outputs(env_dir)

        deploy_frontend_if_exists

        puts "\n   Run `belt server` to view your app locally (auto-connects to the deployed API)."
      end

      def run_backup_only
        validate!
        load_and_apply_env_config!

        puts "belt → running backups for #{@env}\n\n"

        backup_config = load_backup_config
        if backup_config.nil?
          puts "No backup configuration found for #{@env}."
          puts "Create infrastructure/#{@env}/belt.rb to configure backups."
          puts "\nExample:"
          puts '  Belt.configure do |config|'
          puts '    config.backups do'
          puts '      dynamodb :all'
          puts '    end'
          puts '  end'
          exit 1
        end

        run_backup_phase(backup_config)
        puts "\n✅ Backups complete for #{@env}!"
      end

      def run_rebuild
        validate!
        load_and_apply_env_config!
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

      def load_and_apply_env_config!
        @env_config = EnvironmentConfig.load(@env, infra_dir: @infra_dir)
        @env_config.apply!
        print_env_config_info
      end

      def print_env_config_info
        puts "  🔑 Using AWS profile: #{@env_config.aws_profile}" if @env_config.aws_profile?
        return unless @env_config.env_vars?

        @env_config.env_vars.each_key do |key|
          puts "  📌 Setting #{key}"
        end
      end

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

      def run_preflight_checks!
        require_relative 'doctor_command'
        doctor = DoctorCommand.new(preflight: true)
        return if doctor.run

        abort 'Deploy blocked. Fix the issues above, then try again.'
      end

      def validate_aws!
        stdout, status = Open3.capture2('aws', 'sts', 'get-caller-identity', '--output', 'json')
        unless status.success?
          abort "Error: AWS credentials not available.\n" \
                'Run `aws sso login` or configure AWS_PROFILE.'
        end
        @aws_account = begin
          JSON.parse(stdout)['Account']
        rescue StandardError
          nil
        end
      end

      # ─── Backup Phase ───────────────────────────────────────────────

      def run_backups
        backup_config = load_backup_config
        return unless backup_config

        run_backup_phase(backup_config)
        puts ''
      end

      def load_backup_config
        @env_config.backups? ? @env_config.backup_config : nil
      end

      def run_backup_phase(backup_config)
        puts '━━━ pre-deploy backup ━━━'
        app_name = detect_app_name_for_backup
        runner = BackupRunner.new(@env, backup_config, infra_dir: @infra_dir, app_name: app_name)
        runner.run
      end

      def detect_app_name_for_backup
        # Try terraform.tfvars first for the app name
        tfvars_file = File.join(@infra_dir, @env, 'terraform.tfvars')
        if File.exist?(tfvars_file)
          match = File.read(tfvars_file).match(/^\s*app_name\s*=\s*"([^"]+)"/)
          return match[1] if match

          match = File.read(tfvars_file).match(/^\s*project\s*=\s*"([^"]+)"/)
          return match[1] if match
        end

        # Fall back to directory name
        File.basename(@project_root)
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

        puts '  🔧 Fixing stale Gemfile.lock ' \
             "(#{stale_path_gems.join(', ')} referenced as PATH but Gemfile uses RubyGems)"
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

          data = begin
            JSON.parse(output)
          rescue StandardError
            {}
          end

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

      def generate_routes_if_needed
        lambda_dir = find_lambda_dir
        return unless lambda_dir

        generate_routes(lambda_dir)
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

        copy_vendor_cache(build_dir)
        materialize_path_gems!(build_dir)

        puts '    📁 Copied handlers, controllers, models, lib, config'
      end

      # Stage prebuilt .gem files so Docker `bundle install` can install unreleased
      # gems as normal package installs (with specifications/), not path/git layouts.
      # Prefer project-root vendor/cache (next to Gemfile — Bundler's natural path);
      # fall back to lambda/vendor/cache for older layouts.
      def copy_vendor_cache(build_dir)
        cache_dir = [
          File.join(@project_root, 'vendor', 'cache'),
          File.join(@project_root, 'lambda', 'vendor', 'cache')
        ].find { |dir| Dir.exist?(dir) && !Dir.empty?(dir) }
        return unless cache_dir

        dest = File.join(build_dir, 'vendor', 'cache')
        FileUtils.mkdir_p(dest)
        FileUtils.cp_r(Dir.glob(File.join(cache_dir, '*')), dest)
        gem_count = Dir.glob(File.join(dest, '*.gem')).size
        puts "    📦 Copied vendor/cache (#{gem_count} local gem(s))"
      end

      # path: gems install under bundler/gems/ with no specifications/ — Lambda's
      # bare `require 'belt'` can't see them. Build real .gem files into the
      # package's vendor/cache and pin versions in the *build* Gemfile/lock only.
      def materialize_path_gems!(build_dir)
        gems = PathGemMaterializer.materialize!(build_dir, project_root: @project_root)
        return if gems.empty?

        puts "    🔧 Materialized path gem(s) → vendor/cache: #{gems.join(', ')}"
      end

      # path: gems need host-side materialize before Docker install. --rebuild
      # always does it. Full terraform apply needs a conveyor-belt build that
      # includes path-gem materialize (discord-vendor-cache-gemfile-parent+).
      def warn_active_path_gems!
        lockfile = File.join(@project_root, 'Gemfile.lock')
        return unless File.exist?(lockfile)
        return unless File.read(lockfile).match?(/^PATH\n/)

        puts '  ⚠ Gemfile.lock has PATH gems (path: in Gemfile).'
        puts "    Safe now: belt deploy #{@env} --rebuild (always materializes)."
        puts '    Full terraform apply needs conveyor-belt with path-gem materialize.'
        puts '    Or pin a version + drop a built .gem in vendor/cache/'
        puts ''
      end

      def build_gems(build_dir)
        puts '    🐳 Building gems in Docker (Lambda-compatible)...'

        uid = Process.uid
        gid = Process.gid

        image = detect_docker_build_image

        docker_cmd = [
          'docker', 'run', '--rm',
          '--platform', 'linux/amd64',
          '-v', "#{build_dir}:/var/task",
          '-w', '/var/task',
          image,
          '/bin/bash', '-c',
          "bundle config set --local path 'vendor/bundle' && " \
          "bundle config set --local without 'development test' && " \
          'bundle config set silence_root_warning 1 && ' \
          'bundle install --jobs 4 && ' \
          'bundle clean --force && ' \
          "chown -R #{uid}:#{gid} vendor/"
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

      # Reads docker_build_image from the conveyor_belt Terraform resource state.
      # Falls back to DEFAULT_DOCKER_BUILD_IMAGE if state is unavailable or attribute not set.
      def detect_docker_build_image
        env_dir = File.join(@infra_dir, @env)
        return DEFAULT_DOCKER_BUILD_IMAGE unless Dir.exist?(File.join(env_dir, '.terraform'))

        Dir.chdir(env_dir) do
          output, status = Open3.capture2('terraform', 'state', 'show', 'conveyor_belt.main')
          if status.success?
            # Prefer explicit docker_build_image if set
            image_match = output.match(/docker_build_image\s*=\s*"([^"]+)"/)
            if image_match
              image = image_match[1]
              puts "    📦 Using custom build image: #{image}"
              return image
            end

            # Otherwise derive from ruby_version
            version_match = output.match(/ruby_version\s*=\s*"([^"]+)"/)
            if version_match
              version = version_match[1]
              image = "public.ecr.aws/sam/build-ruby#{version}:latest-x86_64"
              puts "    📦 Using build image for Ruby #{version}: #{image}"
              return image
            end
          end
        end

        DEFAULT_DOCKER_BUILD_IMAGE
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
        exts = %w[*.md *.rdoc *.txt *.c *.h *.o Makefile *.log CHANGELOG* HISTORY* LICENSE* README* .gitignore
                  .travis.yml .rubocop.yml Rakefile]
        exts.each do |pattern|
          Dir.glob(File.join(vendor_dir, '**', pattern)).each do |f|
            FileUtils.rm_f(f) if File.file?(f)
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

        FileUtils.rm_f(zip_file)

        unless status.success?
          abort "\n✗ Failed to update Lambda function code.\n  " \
                "Function: #{function_name}\n  " \
                'Check that the function exists and you have permissions.'
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

      def confirm_apply?
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
        FileUtils.rm_f('tfplan')
      end

      def deploy_frontend_if_exists
        frontend_dir = File.join(@project_root, 'frontend')
        return unless Dir.exist?(frontend_dir) && File.exist?(File.join(frontend_dir, 'package.json'))

        puts "\n━━━ frontend deploy ━━━"
        require_relative 'frontend_deploy_command'
        Belt::CLI::FrontendDeployCommand.new(@env).run
      rescue StandardError => e
        puts "\n  ⚠ Frontend deploy failed: #{e.message}"
        puts "    Run `belt deploy frontend #{@env}` manually to retry."
      end

      def print_outputs(env_dir)
        Dir.chdir(env_dir) do
          output = `terraform output 2>/dev/null`.strip
          return if output.empty?

          puts "\nOutputs:"
          output.each_line do |line|
            puts "  #{line}"
          end

          # Show DNS guidance if name_servers are present and this looks like a first deploy
          print_dns_guidance if output.include?('name_servers')
        end
      end

      def print_dns_guidance
        # Check if there's a marker file indicating DNS guidance was already shown
        marker = File.join(@infra_dir, @env, '.dns_configured')
        return if File.exist?(marker)

        domain = detect_domain_from_tfvars
        return unless domain

        puts ''
        puts '  ┌─────────────────────────────────────────────────────────────┐'
        puts '  │ DNS SETUP REQUIRED                                          │'
        puts '  ├─────────────────────────────────────────────────────────────┤'
        puts '  │ Point your domain to the name_servers shown above.          │'
        puts '  │                                                             │'
        puts '  │ • External registrar (GoDaddy, Namecheap, etc.):            │'
        puts '  │   Update nameservers in your registrar\'s DNS settings.      │'
        puts '  │                                                             │'
        puts '  │ • Domain in AWS Route53 Registered Domains:                 │'
        puts '  │   Route53 → Registered Domains → Name servers → Edit.       │'
        puts '  │                                                             │'
        puts "  │ Verify: dig +short NS #{domain.ljust(38)}│"
        puts '  │                                                             │'
        puts '  │ This message won\'t appear on subsequent deploys.            │'
        puts '  └─────────────────────────────────────────────────────────────┘'

        # Create the marker so we don't nag on every deploy
        File.write(marker, "DNS guidance shown at #{Time.now}\n")
      end

      def detect_domain_from_tfvars
        tfvars_file = File.join(@infra_dir, @env, 'terraform.tfvars')
        return nil unless File.exist?(tfvars_file)

        match = File.read(tfvars_file).match(/^\s*domain\s*=\s*"([^"]+)"/)
        match[1] if match
      end
    end
  end
end
