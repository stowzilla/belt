# frozen_string_literal: true

require 'fileutils'
require_relative 'app_detection'
require_relative 'auth_command'
require_relative 'frontend_registry'
require_relative 'generator_registry'
require_relative 'tables_command'
require_relative 'environment_config'
require_relative '../inflector'

module Belt
  module CLI
    class DestroyCommand
      GENERATORS = %w[scaffold resource model controller environment frontend views index auth].freeze

      include AppDetection

      def self.run(args)
        generator = args.shift

        if generator.nil? || generator =~ /\A-/
          print_help
          exit 0
        end

        unless GENERATORS.include?(generator) || GeneratorRegistry.generator_names.include?(generator)
          puts "Unknown generator: '#{generator}'"
          puts "Available: #{(GENERATORS + GeneratorRegistry.generator_names).uniq.join(', ')}"
          puts "\nRun 'belt destroy --help' for usage information."
          exit 1
        end

        # Delegate to gem-provided generator if not a built-in
        unless GENERATORS.include?(generator)
          klass = GeneratorRegistry.find(generator)
          return klass.destroy(args) if klass.respond_to?(:destroy)

          puts "Generator '#{generator}' does not support destroy."
          exit 1
        end

        # Normalize: resource is an alias for scaffold
        generator = 'scaffold' if generator == 'resource'

        case generator
        when 'environment'
          name = args.shift
          if name.nil? || name.empty?
            puts 'Usage: belt destroy environment <name> [--full] [--force] [--skip-terraform]'
            exit 1
          end
          flags = parse_environment_flags(args)
          new(generator, name, [], **flags).destroy
        when 'frontend'
          frontend_name = FrontendRegistry.extract_flag!(args, '--frontend')
          new(generator, nil, [], frontend_name: frontend_name).destroy
        when 'auth'
          Belt::CLI::AuthCommand.destroy(args)
        when 'views'
          frontend_name = FrontendRegistry.extract_flag!(args, '--frontend')
          name = args.shift
          if name.nil? || name.empty?
            puts 'Usage: belt destroy views <name> [--frontend NAME]'
            exit 1
          end
          new(generator, name, args.map { |a| parse_field(a) }, frontend_name: frontend_name).destroy
        when 'index'
          Belt::CLI::IndexCommand.run(['remove'] + args)
        else
          frontend_name = FrontendRegistry.extract_flag!(args, '--frontend')
          name = args.shift
          if name.nil? || name.empty?
            puts "Usage: belt destroy #{generator} <name>"
            exit 1
          end
          new(generator, name, args.map { |a| parse_field(a) }, frontend_name: frontend_name).destroy
        end
      end

      def self.parse_environment_flags(args)
        flags = { force: false, skip_terraform: false, full: false }
        args.each do |arg|
          case arg
          when '--force', '-f'
            flags[:force] = true
          when '--skip-terraform'
            flags[:skip_terraform] = true
          when '--full', '-y'
            flags[:full] = true
          end
        end
        flags
      end

      def self.parse_field(arg)
        name, type = arg.split(':', 2)
        { name: name, type: type || 'string' }
      end

      def self.print_help
        puts <<~HELP
          Usage: belt destroy <generator> <name> [field:type ...]
                 belt d <generator> <name> [field:type ...]

          Removes files and references created by `belt generate`.

          Generators:
            scaffold      Remove model, controller, routes, schema, and views
            resource      Alias for scaffold
            model         Remove an ActiveItem model
            controller    Remove a controller
            auth          Remove Cognito user pool infrastructure
            environment   Remove a deployment environment and tear down infrastructure
            frontend      Remove a frontend directory (use --frontend NAME when several exist)
            views         Remove React pages for a resource

          Environment options:
            --full, -y           Non-interactive teardown: ALWAYS run terraform
                                 destroy, then delete local files AND purge the
                                 remote terraform state from S3, no prompts
                                 (use this for CI / agents tearing down ephemeral envs)
            --force, -f          Skip all prompts but SKIP terraform destroy —
                                 only deletes local files (leaves cloud resources)
            --skip-terraform     Delete local files without running terraform destroy

          Examples:
            belt d scaffold post title:string body:text status:string
            belt d model user
            belt d controller comments
            belt d environment staging
            belt d environment dev --skip-terraform
            belt d environment dev --force
            belt d environment pr-1234 --full    # full non-interactive teardown
            belt d frontend
            belt d frontend --frontend ops
            belt d views post
            belt d views post --frontend ops

          ⚠ This is destructive. Files will be permanently deleted.

          For environments: if terraform state is detected, you'll be prompted to run
          `terraform destroy` first to tear down cloud resources before removing files.
          Pass --full to run the whole teardown non-interactively (destroy + delete).
        HELP
      end

      # -- keyword options for destroy flags
      def initialize(generator, name, fields, force: false, skip_terraform: false, full: false, frontend_name: nil)
        @generator = generator
        # Environment names preserve hyphens (matching `belt g environment`);
        # other generators normalize to underscores for valid Ruby identifiers.
        @name = if generator == 'environment'
                  name&.downcase&.gsub(/[^a-z0-9_-]/, '')
                else
                  name&.downcase&.gsub(/[^a-z0-9_]/, '_')
                end
        @fields = fields
        @force = force
        @skip_terraform = skip_terraform
        @full = full
        @frontend_name = frontend_name
        @app_name = detect_namespace
        @singular_name = @name ? Belt::Inflector.singularize(@name) : nil
        @resource_name = @singular_name ? Belt::Inflector.pluralize(@singular_name) : nil
        @class_name = @singular_name ? Belt::Inflector.classify(@singular_name) : nil
        @removed = []
        @updated = []
      end

      def destroy
        case @generator
        when 'scaffold'  then destroy_scaffold
        when 'model'     then destroy_model
        when 'controller' then destroy_controller
        when 'environment' then destroy_environment
        when 'frontend'  then destroy_frontend
        when 'views'     then destroy_views
        end

        print_summary
      end

      private

      def destroy_scaffold
        destroy_model
        destroy_controller
        remove_routes
        destroy_views
        puts "\n✓ Scaffold '#{@singular_name}' destroyed!"
      end

      def destroy_model
        path = "lambda/models/#{@singular_name}.rb"
        remove_file(path)
        remove_schema
        sync_tables
      end

      def destroy_controller
        path = "lambda/controllers/#{@app_name}/#{@resource_name}_controller.rb"
        remove_file(path)
      end

      def destroy_environment
        dir = "infrastructure/#{@name}"

        unless Dir.exist?(dir)
          puts "✗ Environment '#{@name}' not found at #{dir}/"
          exit 1
        end

        # Check if any environments are nested under this one
        nested_children = find_nested_children(@name)
        if nested_children.any?
          puts "⚠  The following environments are nested under '#{@name}':"
          nested_children.each { |child| puts "     - #{child}" }
          puts ''
          puts '   Destroying the parent will leave them with broken DNS references.'
          puts '   Consider destroying nested environments first:'
          nested_children.each { |child| puts "     belt destroy environment #{child}" }
          puts ''
          unless @force || @full
            print '   Continue anyway? [y/N] '
            response = $stdin.gets&.strip&.downcase
            unless response&.start_with?('y')
              puts 'Cancelled.'
              exit 0
            end
          end
        end

        # Apply the environment's AWS profile + env vars from infrastructure/<env>/belt.rb
        # BEFORE any terraform/aws calls, so both remote-state detection and the
        # subsequent destroy authenticate against the correct account. Without this,
        # terraform inherits whatever AWS_PROFILE is in the shell, which may point at
        # the wrong account (mirrors `belt deploy` / `belt terraform`).
        apply_env_config! unless @skip_terraform

        # Check if terraform state exists (infra may still be live)
        if !@skip_terraform && terraform_state_exists?(dir)
          puts "⚠  Environment '#{@name}' appears to have active infrastructure."
          puts "   Terraform state was found — resources may still be running.\n\n"

          if @full
            # Fully non-interactive teardown (CI / agents): always run terraform
            # destroy, then delete files. This is the flag to reach for when an
            # automated workflow spins an environment up and tears it down.
            run_terraform_destroy(dir)
          elsif @force
            puts '   --force passed, skipping terraform destroy.'
          else
            puts '   Options:'
            puts '     1) Run `terraform destroy` to tear down infrastructure first (recommended)'
            puts '     2) Skip terraform and just delete the local files (--skip-terraform)'
            puts "     3) Cancel\n\n"

            print "   Run terraform destroy for '#{@name}'? [y/N/skip] "
            response = $stdin.gets&.strip&.downcase

            case response
            when 'y', 'yes'
              run_terraform_destroy(dir)
            when 'skip', 's'
              puts '   Skipping terraform destroy.'
            else
              puts 'Cancelled.'
              exit 0
            end
          end
        end

        # Final confirmation before deleting files
        unless @force || @full
          print "\nPermanently delete #{dir}/? [y/N] "
          response = $stdin.gets&.strip&.downcase
          unless response&.start_with?('y')
            puts 'Cancelled.'
            exit 0
          end
        end

        # Purge remote state from S3 when --full is used (complete ephemeral cleanup)
        purge_terraform_state(dir) if @full

        FileUtils.rm_rf(dir)
        @removed << dir
        puts "  remove  #{dir}/"
        puts "\n✓ Environment '#{@name}' destroyed!"

        # Check if DNS delegation exists and warn about cleanup
        warn_about_dns_delegation(@name)
      end

      def find_nested_children(env_name)
        nested_children = []
        Dir.glob('infrastructure/*/terraform.tfvars').each do |tfvars_file|
          next if tfvars_file.include?('/dns/')
          next if tfvars_file.include?('/modules/')

          content = File.read(tfvars_file)
          next unless content =~ /^\s*parent_environment\s*=\s*"#{Regexp.escape(env_name)}"/

          child_env = File.basename(File.dirname(tfvars_file))
          nested_children << child_env
        end
        nested_children
      end

      def terraform_state_exists?(dir)
        # Check for local .terraform directory (initialized state)
        return true if Dir.exist?(File.join(dir, '.terraform'))

        # Check if backend.tf exists (remote state configured)
        backend_file = File.join(dir, 'backend.tf')
        return false unless File.exist?(backend_file)

        # Try to query remote state — if terraform is initialized and state exists,
        # the environment likely has live resources
        Dir.chdir(dir) do
          # Quick check: does `terraform show` return anything?
          output = `terraform show -no-color 2>&1`
          Process.last_status.success? && !output.strip.empty? && !output.include?('No state')
        end
      rescue StandardError
        # If we can't determine state, assume it might exist and warn
        true
      end

      def warn_about_dns_delegation(env_name)
        # Check if this is a nested environment (DNS records are in parent's zone, handled by terraform)
        tfvars_file = "infrastructure/#{env_name}/terraform.tfvars"
        if File.exist?(tfvars_file)
          tfvars_content = File.read(tfvars_file)
          if tfvars_content =~ /^\s*parent_environment\s*=\s*"([^"]+)"/
            parent_env = ::Regexp.last_match(1)
            puts ''
            puts "ℹ  This was a nested environment under '#{parent_env}'."
            puts '   The DNS A record in the parent zone was deleted by terraform destroy.'
            return
          end
        end

        # Check if any other environments are nested under this one
        warn_about_nested_children(env_name)

        # Check for standalone environment DNS delegation
        dns_tfvars = 'infrastructure/dns/terraform.tfvars'
        return unless File.exist?(dns_tfvars)

        content = File.read(dns_tfvars)
        # Only match a real HCL entry (e.g. "  dev = [") at the start of a line,
        # not the commented-out examples in the tfvars template (e.g. "#   dev = [").
        # This mirrors the anchored patterns DNSCommand uses when writing entries.
        return unless content =~ /^\s*#{Regexp.escape(env_name)}\s*=/

        puts ''
        puts '⚠  DNS delegation still exists for this environment.'
        puts '   To clean up the root zone delegation:'
        puts ''
        puts "     belt dns remove #{env_name}"
        puts '     belt dns deploy'
      end

      def warn_about_nested_children(env_name)
        nested_children = []
        Dir.glob('infrastructure/*/terraform.tfvars').each do |tfvars_file|
          next if tfvars_file.include?('/dns/')

          content = File.read(tfvars_file)
          next unless content =~ /^\s*parent_environment\s*=\s*"#{Regexp.escape(env_name)}"/

          child_env = File.basename(File.dirname(tfvars_file))
          nested_children << child_env
        end

        return if nested_children.empty?

        puts ''
        puts '⚠  The following environments were nested under this one:'
        nested_children.each { |child| puts "     - #{child}" }
        puts '   They may have dangling DNS references. Consider destroying them first,'
        puts '   or manually cleaning up their Route53 records.'
      end

      def run_terraform_destroy(dir)
        puts "\n━━━ terraform destroy (#{@name}) ━━━"

        Dir.chdir(dir) do
          # Initialize if needed
          unless Dir.exist?('.terraform')
            puts '  Initializing terraform...'
            unless system('terraform', 'init', '-input=false')
              puts "\n✗ terraform init failed. You may need to destroy manually:"
              puts "  cd #{dir} && terraform init && terraform destroy"
              exit 1
            end
          end

          # Empty S3 buckets before destroy — terraform can't delete non-empty buckets
          empty_s3_buckets_in_state

          # Run destroy with auto-approve (user already confirmed)
          unless system('terraform', 'destroy', '-auto-approve')
            puts "\n✗ terraform destroy failed."
            puts '  Infrastructure may still be running. Fix and retry, or use --skip-terraform.'
            exit 1
          end
        end

        puts '  ✓ Infrastructure destroyed.'
      end

      # Purge the terraform state file from S3 after a full destroy.
      # This leaves zero trace of ephemeral environments in the state bucket.
      def purge_terraform_state(dir)
        backend_file = File.join(dir, 'backend.tf')
        return unless File.exist?(backend_file)

        content = File.read(backend_file)

        # Extract bucket and key from backend config
        bucket_match = content.match(/bucket\s*=\s*"([^"]+)"/)
        key_match = content.match(/key\s*=\s*"([^"]+)"/)

        return unless bucket_match && key_match

        bucket = bucket_match[1]
        key = key_match[1]

        puts '  Purging terraform state from S3...'

        # Delete the state file
        result = `aws s3 rm "s3://#{bucket}/#{key}" 2>&1`
        if Process.last_status.success?
          puts "    ✓ Deleted s3://#{bucket}/#{key}"
        else
          puts "    ⚠ Could not delete state file: #{result.strip}" unless result.include?('delete: s3://')
        end

        # Also try to delete the state lock file if it exists (DynamoDB-based locking
        # uses a separate mechanism, but some setups have .tflock files)
        lock_key = key.sub(/\.tfstate$/, '.tfstate.lock')
        `aws s3 rm "s3://#{bucket}/#{lock_key}" 2>/dev/null`

        # Try to clean up the environment's directory in the bucket if empty
        # (e.g., if the key is "myapp/fizzy123/terraform.tfstate", try to remove the "fizzy123" prefix)
        env_prefix = key.sub(%r{/[^/]+$}, '')
        return unless env_prefix != key

        # List remaining objects under this prefix
        remaining = `aws s3 ls "s3://#{bucket}/#{env_prefix}/" 2>/dev/null`
        return unless Process.last_status.success? && remaining.strip.empty?

        puts "    ✓ State directory s3://#{bucket}/#{env_prefix}/ is now empty"
      end

      # Load infrastructure/<env>/belt.rb and apply its aws_profile + env vars to
      # the current process so terraform (and any aws CLI calls during destroy)
      # authenticate against the right account. Mirrors DeployCommand / TerraformCommand.
      def apply_env_config!
        env_config = EnvironmentConfig.load(@name)
        env_config.apply!
        puts "  🔑 Using AWS profile: #{env_config.aws_profile}" if env_config.aws_profile?
      end

      def empty_s3_buckets_in_state
        output = `terraform state list 2>/dev/null`
        return unless Process.last_status.success?

        bucket_resources = output.lines.map(&:strip).grep(/\Aaws_s3_bucket\./)
        return if bucket_resources.empty?

        bucket_resources.each do |resource|
          bucket_name = resolve_bucket_name(resource)
          next unless bucket_name

          empty_s3_bucket(bucket_name)
        end
      end

      def resolve_bucket_name(resource)
        output = `terraform state show '#{resource}' 2>/dev/null`
        return nil unless Process.last_status.success?

        match = output.match(/^\s*bucket\s*=\s*"([^"]+)"/)
        match&.[](1)
      end

      def empty_s3_bucket(bucket_name)
        # Check if bucket exists
        `aws s3api head-bucket --bucket '#{bucket_name}' 2>&1`
        return unless Process.last_status.success?

        puts "  Emptying S3 bucket: #{bucket_name}"

        # Delete all object versions (handles versioned buckets)
        `aws s3 rm 's3://#{bucket_name}' --recursive 2>/dev/null`

        # Also delete versioned objects and delete markers
        delete_all_versions(bucket_name)
      end

      def delete_all_versions(bucket_name)
        loop do
          output = `aws s3api list-object-versions --bucket '#{bucket_name}' --max-items 1000 2>/dev/null`
          break unless Process.last_status.success?

          begin
            data = JSON.parse(output)
          rescue JSON::ParserError
            break
          end

          versions = (data['Versions'] || []) + (data['DeleteMarkers'] || [])
          break if versions.empty?

          # Build delete objects payload
          objects = versions.map do |v|
            { 'Key' => v['Key'], 'VersionId' => v['VersionId'] }
          end

          delete_payload = JSON.generate({ 'Objects' => objects, 'Quiet' => true })

          # Use a temp file for the payload since it can be large
          require 'tempfile'
          Tempfile.create(['delete-objects', '.json']) do |f|
            f.write(delete_payload)
            f.flush
            `aws s3api delete-objects --bucket '#{bucket_name}' --delete 'file://#{f.path}' 2>/dev/null`
          end

          # If there's no next token, we're done
          break unless data['NextToken'] || data['IsTruncated']
        end
      end

      def destroy_frontend
        frontend = FrontendRegistry.new.resolve!(@frontend_name)
        dir = frontend.path
        if Dir.exist?(dir)
          FileUtils.rm_rf(dir)
          @removed << dir
          puts "  remove  #{dir}/"

          tf_file = File.join('infrastructure/modules/app', "#{frontend.tf_name}.tf")
          if File.exist?(tf_file)
            FileUtils.rm_f(tf_file)
            @removed << tf_file
            puts "  remove  #{tf_file}"
          end

          puts "\n✓ #{frontend.label.capitalize} removed!"
        else
          puts "✗ No #{dir}/ directory found."
          exit 1
        end
      end

      def target_frontends
        registry = FrontendRegistry.new
        return [] if registry.empty?

        if @frontend_name
          [registry.resolve!(@frontend_name)]
        else
          registry.all
        end
      end

      def destroy_views
        return unless @resource_name

        targets = target_frontends
        if targets.empty?
          pages_dir = "frontend/src/pages/#{@resource_name}"
          if Dir.exist?(pages_dir)
            FileUtils.rm_rf(pages_dir)
            @removed << pages_dir
            puts "  remove  #{pages_dir}/"
          end
          remove_view_routes_from('frontend/src/App.jsx')
          return
        end

        targets.each do |frontend|
          pages_dir = "#{frontend.src_dir}/pages/#{@resource_name}"
          if Dir.exist?(pages_dir)
            FileUtils.rm_rf(pages_dir)
            @removed << pages_dir
            puts "  remove  #{pages_dir}/"
          end
          remove_view_routes_from(frontend.app_jsx)
        end
      end

      def remove_file(path)
        if File.exist?(path)
          File.delete(path)
          @removed << path
          puts "  remove  #{path}"

          # Clean up empty parent directories
          dir = File.dirname(path)
          while dir != '.' && Dir.exist?(dir) && Dir.empty?(dir)
            Dir.rmdir(dir)
            puts "  remove  #{dir}/"
            dir = File.dirname(dir)
          end
        else
          puts "  skip    #{path} (not found)"
        end
      end

      def remove_routes
        routes_file = find_routes_file_path
        return unless routes_file && File.exist?(routes_file)

        content = File.read(routes_file)
        original = content.dup

        # Remove "resources :posts" or "resources :posts, tables: [...]" line
        content.gsub!(/^\s*resources :#{@resource_name}.*\n/, '')

        if content != original
          File.write(routes_file, content)
          @updated << routes_file
          puts "  update  #{routes_file}"
        end

        # Update route manifest
        remove_route_manifest_entries
      end

      def remove_route_manifest_entries
        manifest_file = "lambda/lib/routes/#{@app_name}_routes.rb"
        return unless File.exist?(manifest_file)

        content = File.read(manifest_file)
        original = content.dup

        # Remove route entries for this controller
        content.gsub!(/^\s*\{ verb: .+?controller: '#{@resource_name}'.+?\},?\n/, '')

        # Clean up trailing commas and empty arrays
        content.gsub!(/,(\s*\n\s*\]\.freeze)/, '\1')

        return unless content != original

        File.write(manifest_file, content)
        @updated << manifest_file
        puts "  update  #{manifest_file}"
      end

      def remove_schema
        schema_file = find_schema_file_path
        return unless schema_file && File.exist?(schema_file)

        content = File.read(schema_file)
        original = content.dup

        # Remove the model block for this resource
        content.gsub!(/\n?\s*model :#{@singular_name} do\n.*?\n\s*end\n?/m, "\n")

        # Clean up excessive blank lines
        content.gsub!(/\n{3,}/, "\n\n")

        return unless content != original

        File.write(schema_file, content)
        @updated << schema_file
        puts "  update  #{schema_file}"
      end

      def sync_tables
        Belt::CLI::TablesCommand.sync_all_environments
      end

      def remove_view_routes_from(app_jsx)
        return unless File.exist?(app_jsx)

        content = File.read(app_jsx)
        original = content.dup

        # Remove import lines for this resource's pages
        content.gsub!(%r{^import #{@class_name}\w* from './pages/#{@resource_name}/.*'\n}, '')

        # Remove Route elements for this resource
        content.gsub!(%r{^\s*<Route path="/#{@resource_name}.*?/>\n}, '')

        return unless content != original

        File.write(app_jsx, content)
        @updated << app_jsx
        puts "  update  #{app_jsx}"
      end

      def print_summary
        return if @removed.empty? && @updated.empty?

        puts "\nSummary:"
        puts "  Removed: #{@removed.length} file(s)/dir(s)" unless @removed.empty?
        puts "  Updated: #{@updated.length} file(s)" unless @updated.empty?
      end
    end
  end
end
