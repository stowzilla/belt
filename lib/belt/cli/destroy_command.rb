# frozen_string_literal: true

require 'fileutils'
require_relative 'app_detection'
require_relative 'generator_registry'
require_relative 'tables_command'
require_relative '../inflector'

module Belt
  module CLI
    class DestroyCommand
      GENERATORS = %w[scaffold resource model controller environment frontend views].freeze

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
            puts 'Usage: belt destroy environment <name> [--force] [--skip-terraform]'
            exit 1
          end
          flags = parse_environment_flags(args)
          new(generator, name, [], **flags).destroy
        when 'frontend'
          new(generator, nil, []).destroy
        when 'views'
          name = args.shift
          if name.nil? || name.empty?
            puts 'Usage: belt destroy views <name>'
            exit 1
          end
          new(generator, name, args.map { |a| parse_field(a) }).destroy
        else
          name = args.shift
          if name.nil? || name.empty?
            puts "Usage: belt destroy #{generator} <name>"
            exit 1
          end
          new(generator, name, args.map { |a| parse_field(a) }).destroy
        end
      end

      def self.parse_environment_flags(args)
        flags = { force: false, skip_terraform: false }
        args.each do |arg|
          case arg
          when '--force', '-f'
            flags[:force] = true
          when '--skip-terraform'
            flags[:skip_terraform] = true
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
            environment   Remove a deployment environment and tear down infrastructure
            frontend      Remove the frontend/ directory
            views         Remove React pages for a resource

          Environment options:
            --force, -f          Skip all prompts (CI mode)
            --skip-terraform     Delete local files without running terraform destroy

          Examples:
            belt d scaffold post title:string body:text status:string
            belt d model user
            belt d controller comments
            belt d environment staging
            belt d environment dev --skip-terraform
            belt d environment dev --force
            belt d frontend
            belt d views post

          ⚠ This is destructive. Files will be permanently deleted.

          For environments: if terraform state is detected, you'll be prompted to run
          `terraform destroy` first to tear down cloud resources before removing files.
        HELP
      end

      def initialize(generator, name, fields, force: false, skip_terraform: false)
        @generator = generator
        @name = name&.downcase&.gsub(/[^a-z0-9_]/, '_')
        @fields = fields
        @force = force
        @skip_terraform = skip_terraform
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

        # Check if terraform state exists (infra may still be live)
        if !@skip_terraform && terraform_state_exists?(dir)
          puts "⚠  Environment '#{@name}' appears to have active infrastructure."
          puts "   Terraform state was found — resources may still be running.\n\n"

          if @force
            puts "   --force passed, skipping terraform destroy."
          else
            puts "   Options:"
            puts "     1) Run `terraform destroy` to tear down infrastructure first (recommended)"
            puts "     2) Skip terraform and just delete the local files (--skip-terraform)"
            puts "     3) Cancel\n\n"

            print "   Run terraform destroy for '#{@name}'? [y/N/skip] "
            response = $stdin.gets&.strip&.downcase

            case response
            when 'y', 'yes'
              run_terraform_destroy(dir)
            when 'skip', 's'
              puts "   Skipping terraform destroy."
            else
              puts "Cancelled."
              exit 0
            end
          end
        end

        # Final confirmation before deleting files
        unless @force
          print "\nPermanently delete #{dir}/? [y/N] "
          response = $stdin.gets&.strip&.downcase
          unless response&.start_with?('y')
            puts 'Cancelled.'
            exit 0
          end
        end

        FileUtils.rm_rf(dir)
        @removed << dir
        puts "  remove  #{dir}/"
        puts "\n✓ Environment '#{@name}' destroyed!"
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
          $?.success? && !output.strip.empty? && !output.include?('No state')
        end
      rescue StandardError
        # If we can't determine state, assume it might exist and warn
        true
      end

      def run_terraform_destroy(dir)
        puts "\n━━━ terraform destroy (#{@name}) ━━━"

        Dir.chdir(dir) do
          # Initialize if needed
          unless Dir.exist?('.terraform')
            puts "  Initializing terraform..."
            unless system('terraform', 'init', '-input=false')
              puts "\n✗ terraform init failed. You may need to destroy manually:"
              puts "  cd #{dir} && terraform init && terraform destroy"
              exit 1
            end
          end

          # Run destroy with auto-approve (user already confirmed)
          unless system('terraform', 'destroy', '-auto-approve')
            puts "\n✗ terraform destroy failed."
            puts "  Infrastructure may still be running. Fix and retry, or use --skip-terraform."
            exit 1
          end
        end

        puts "  ✓ Infrastructure destroyed."
      end

      def destroy_frontend
        dir = 'frontend'
        if Dir.exist?(dir)
          FileUtils.rm_rf(dir)
          @removed << dir
          puts "  remove  #{dir}/"

          # Remove frontend.tf from the module
          module_frontend = 'infrastructure/modules/app/frontend.tf'
          if File.exist?(module_frontend)
            FileUtils.rm_f(module_frontend)
            @removed << module_frontend
            puts "  remove  #{module_frontend}"
          end

          puts "\n✓ Frontend removed!"
        else
          puts '✗ No frontend/ directory found.'
          exit 1
        end
      end

      def destroy_views
        return unless @resource_name

        pages_dir = "frontend/src/pages/#{@resource_name}"

        if Dir.exist?(pages_dir)
          FileUtils.rm_rf(pages_dir)
          @removed << pages_dir
          puts "  remove  #{pages_dir}/"
        end

        remove_view_routes
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

      def remove_view_routes
        app_jsx = 'frontend/src/App.jsx'
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
