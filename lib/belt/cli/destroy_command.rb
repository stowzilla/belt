# frozen_string_literal: true

require 'fileutils'
require_relative 'app_detection'
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

        unless GENERATORS.include?(generator)
          puts "Unknown generator: '#{generator}'"
          puts "Available: #{GENERATORS.uniq.join(', ')}"
          puts "\nRun 'belt destroy --help' for usage information."
          exit 1
        end

        # Normalize: resource is an alias for scaffold
        generator = 'scaffold' if generator == 'resource'

        case generator
        when 'environment'
          name = args.shift
          if name.nil? || name.empty?
            puts 'Usage: belt destroy environment <name>'
            exit 1
          end
          new(generator, name, []).destroy
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
            environment   Remove a deployment environment directory
            frontend      Remove the frontend/ directory
            views         Remove React pages for a resource

          Examples:
            belt d scaffold post title:string body:text status:string
            belt d model user
            belt d controller comments
            belt d environment staging
            belt d frontend
            belt d views post

          ⚠ This is destructive. Files will be permanently deleted.
        HELP
      end

      def initialize(generator, name, fields)
        @generator = generator
        @name = name&.downcase&.gsub(/[^a-z0-9_]/, '_')
        @fields = fields
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
        remove_schema
        sync_tables
        destroy_views
        puts "\n✓ Scaffold '#{@singular_name}' destroyed!"
      end

      def destroy_model
        path = "lambda/models/#{@singular_name}.rb"
        remove_file(path)
      end

      def destroy_controller
        path = "lambda/controllers/#{@app_name}/#{@resource_name}_controller.rb"
        remove_file(path)
      end

      def destroy_environment
        dir = "infrastructure/#{@name}"
        if Dir.exist?(dir)
          FileUtils.rm_rf(dir)
          @removed << dir
          puts "  remove  #{dir}/"
          puts "\n✓ Environment '#{@name}' destroyed!"
        else
          puts "✗ Environment '#{@name}' not found at #{dir}/"
          exit 1
        end
      end

      def destroy_frontend
        dir = 'frontend'
        if Dir.exist?(dir)
          FileUtils.rm_rf(dir)
          @removed << dir
          puts "  remove  #{dir}/"

          # Remove frontend.tf and revert frontend_urls in main.tf for each environment
          Dir.glob('infrastructure/*/frontend.tf').each do |frontend_tf|
            FileUtils.rm_f(frontend_tf)
            puts "  remove  #{frontend_tf}"

            env_dir = File.dirname(frontend_tf)
            main_tf = File.join(env_dir, 'main.tf')
            revert_main_tf_frontend_urls(main_tf)
          end

          puts "\n✓ Frontend removed!"
        else
          puts '✗ No frontend/ directory found.'
          exit 1
        end
      end

      def revert_main_tf_frontend_urls(main_tf)
        return unless File.exist?(main_tf)

        content = File.read(main_tf)
        return unless content.include?('aws_cloudfront_distribution.frontend.domain_name')

        # Replace the multi-line concat block back to a simple conditional
        replaced = content.sub(
          /^\s*frontend_urls\s*=\s*concat\(\n(?:.*\n)*?\s*\)\s*\n/,
          "  frontend_urls     = var.environment == \"prod\" ? [] : [\"http://localhost:3000\"]\n"
        )

        if replaced != content
          File.write(main_tf, replaced)
          puts "  update  #{main_tf} (reverted frontend_urls)"
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
        routes_file = 'infrastructure/routes.tf.rb'
        return unless File.exist?(routes_file)

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

        if content != original
          File.write(manifest_file, content)
          @updated << manifest_file
          puts "  update  #{manifest_file}"
        end
      end

      def remove_schema
        schema_file = 'infrastructure/schema.tf.rb'
        return unless File.exist?(schema_file)

        content = File.read(schema_file)
        original = content.dup

        # Remove the model block for this resource
        content.gsub!(/\n?\s*model :#{@singular_name} do\n.*?\n\s*end\n?/m, "\n")

        # Clean up excessive blank lines
        content.gsub!(/\n{3,}/, "\n\n")

        if content != original
          File.write(schema_file, content)
          @updated << schema_file
          puts "  update  #{schema_file}"
        end
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
        content.gsub!(/^import #{@class_name}\w* from '.\/pages\/#{@resource_name}\/.*'\n/, '')

        # Remove Route elements for this resource
        content.gsub!(/^\s*<Route path="\/#{@resource_name}.*?\/>\n/, '')

        if content != original
          File.write(app_jsx, content)
          @updated << app_jsx
          puts "  update  #{app_jsx}"
        end
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
