# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'
require_relative 'environment_command'
require_relative 'frontend_command'
require_relative 'views_command'

module Belt
  module CLI
    class GenerateCommand
      TEMPLATE_DIR = File.expand_path('../../templates/generate', __dir__)
      GENERATORS = %w[scaffold resource model controller environment frontend views].freeze

      include AppDetection

      FIELD_TYPES = %w[string text integer float boolean date datetime].freeze

      GENERATOR_HELP = {
        'scaffold' => {
          description: 'Generate a model, controller, routes, schema, and views for a REST resource.',
          usage: 'belt generate scaffold <name> [field:type ...] [options]',
          options: [
            ['--skip-views', 'Skip generating frontend view pages']
          ],
          examples: [
            ['belt g scaffold post title:string body:text', 'Post with title and body fields'],
            ['belt g scaffold comment author:string body:text status:string', 'Scaffold with multiple fields'],
            ['belt g scaffold task --skip-views', 'Scaffold without frontend pages']
          ],
          notes: <<~NOTES
            Creates:
              lambda/models/<name>.rb                            Model with validations and fields
              lambda/controllers/<app>/<names>_controller.rb    RESTful controller (index, show, create, update, destroy)
              infrastructure/routes.tf.rb                        Route entry added
              infrastructure/schema.tf.rb                        DynamoDB table schema added
              lambda/lib/routes/<app>_routes.rb                  Route manifest updated
              frontend/src/pages/<names>/                        React pages (if frontend exists)

            Alias: `belt g resource` works the same way.
          NOTES
        },
        'model' => {
          description: 'Generate an ActiveItem model with validations and DynamoDB field definitions.',
          usage: 'belt generate model <name> [field:type ...]',
          options: [],
          examples: [
            ['belt g model user email:string name:string', 'User model with email and name'],
            ['belt g model event title:string starts_at:datetime', 'Event model with datetime field']
          ],
          notes: <<~NOTES
            Creates:
              lambda/models/<name>.rb    Model class inheriting from ActiveItem::Base
          NOTES
        },
        'controller' => {
          description: 'Generate a controller with standard REST actions.',
          usage: 'belt generate controller <name>',
          options: [],
          examples: [
            ['belt g controller posts', 'Posts controller with CRUD actions'],
            ['belt g controller admin/users', 'Namespaced controller']
          ],
          notes: <<~NOTES
            Creates:
              lambda/controllers/<app>/<name>_controller.rb    Controller class
          NOTES
        }
      }.freeze

      def self.run(args)
        generator = args.shift

        # Top-level help: belt generate --help or belt generate (no args)
        if generator.nil? || generator =~ /\A-/
          print_generate_help
          exit 0
        end

        unless GENERATORS.include?(generator)
          puts "Unknown generator: '#{generator}'"
          puts "Available generators: #{(GENERATORS - ['resource']).join(', ')}"
          puts "\nRun 'belt generate --help' for usage information."
          exit 1
        end

        # Normalize: resource is an alias for scaffold
        generator = 'scaffold' if generator == 'resource'

        # Per-generator help: belt g scaffold --help
        if args.include?('--help') || args.include?('-h')
          print_generator_help(generator)
          exit 0
        end

        return Belt::CLI::EnvironmentCommand.run(args) if generator == 'environment'

        return Belt::CLI::FrontendCommand.run(args) if generator == 'frontend'

        return Belt::CLI::ViewsCommand.run(args) if generator == 'views'

        name = args.shift
        if name.nil? || name.empty?
          print_generator_help(generator)
          exit 0
        end

        validate_resource_name!(name, generator)

        skip_views = args.delete('--skip-views')
        fields = args.map { |arg| parse_field(arg) }
        new(generator, name, fields, skip_views: skip_views).generate
      end

      def self.parse_field(arg)
        name, type = arg.split(':', 2)
        { name: name, type: type || 'string' }
      end

      RESERVED_NAMES = %w[
        help new edit create update destroy index show delete remove
        application base controller model resource generate
        belt setup environment frontend views routes
      ].freeze

      def self.validate_resource_name!(name, generator)
        errors = []

        errors << 'must start with a letter' unless name.match?(/\A[a-zA-Z]/)
        errors << 'must be at least 2 characters' if name.length < 2
        errors << 'must only contain letters, numbers, and underscores' unless name.match?(/\A[a-zA-Z][a-zA-Z0-9_]*\z/)
        errors << 'must not start or end with an underscore' if name.match?(/\A_|_\z/)
        errors << 'must not contain consecutive underscores' if name.include?('__')
        errors << "is a reserved name" if RESERVED_NAMES.include?(name.downcase.chomp('s'))
        errors << "is a reserved name" if RESERVED_NAMES.include?(name.downcase)

        return if errors.empty?

        puts "\n✗ Invalid #{generator} name '#{name}':"
        errors.uniq.each { |e| puts "  - #{e}" }
        puts "\nName must start with a letter, be at least 2 characters, and contain only letters, numbers, and single underscores."
        exit 1
      end

      def self.print_generate_help
        puts <<~HELP
          Usage: belt generate <generator> <name> [field:type ...] [options]
                 belt g <generator> <name> [field:type ...] [options]

          Generators:
            scaffold      Generate model, controller, routes, schema, and views (full REST resource)
            model         Generate an ActiveItem model
            controller    Generate a controller
            environment   Create a new deployment environment
            frontend      Scaffold a frontend app (react, vue, svelte)
            views         Generate React pages for a resource

          Aliases:
            resource      Same as scaffold

          Field Types:
            #{FIELD_TYPES.join(', ')}

          Examples:
            belt g scaffold post title:string body:text status:string
            belt g model user email:string name:string
            belt g controller comments
            belt g environment staging
            belt g frontend react
            belt g views post title:string body:text

          Run 'belt generate <generator> --help' for detailed help on a specific generator.
        HELP
      end

      def self.print_generator_help(generator)
        info = GENERATOR_HELP[generator]

        unless info
          puts "Usage: belt generate #{generator} <name>"
          puts "\nRun 'belt generate #{generator} --help' is not yet documented."
          puts "Try 'belt generate --help' for the full list of generators."
          return
        end

        puts info[:description]
        puts
        puts "Usage: #{info[:usage]}"

        if info[:options].any?
          puts "\nOptions:"
          info[:options].each do |flag, desc|
            puts "  %-20s %s" % [flag, desc]
          end
        end

        puts "\nField Types:"
        puts "  #{FIELD_TYPES.join(', ')}"

        puts "\nExamples:"
        info[:examples].each do |cmd, desc|
          puts "  #{cmd}"
          puts "    #{desc}" if desc
        end

        puts "\n#{info[:notes]}" if info[:notes]

        puts "Naming Rules:"
        puts "  - Must start with a letter"
        puts "  - At least 2 characters"
        puts "  - Letters, numbers, and single underscores only"
        puts "  - No leading/trailing/consecutive underscores"
        puts "  - Cannot use reserved names (help, new, create, destroy, etc.)"
      end

      def initialize(generator, name, fields, skip_views: false)
        @generator = generator
        @name = name.downcase.gsub(/[^a-z0-9_]/, '_')
        @fields = fields
        @skip_views = skip_views
        @app_name = detect_namespace
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
        @resource_name = @name.end_with?('s') ? @name : "#{@name}s"
        @singular_name = @name.end_with?('s') ? @name.chomp('s') : @name
        @class_name = @singular_name.split('_').map(&:capitalize).join
      end

      def generate
        case @generator
        when 'scaffold'  then generate_resource
        when 'model'     then generate_model
        when 'controller' then generate_controller
        end
      end

      private

      def generate_resource
        generate_model
        generate_controller
        inject_routes
        inject_schema
        generate_views_if_frontend
        puts "\n✓ Scaffold '#{@singular_name}' generated!"
        puts "\nFiles created/updated:"
        puts "  lambda/models/#{@singular_name}.rb"
        puts "  lambda/controllers/#{@app_name}/#{@resource_name}_controller.rb"
        puts '  infrastructure/routes.tf.rb (updated)'
        puts '  infrastructure/schema.tf.rb (updated)'
        puts "  lambda/lib/routes/#{@app_name}_routes.rb (updated)"
        puts "  frontend/src/pages/#{@resource_name}/ (views)" if Dir.exist?('frontend/src')
      end

      def generate_model
        dest = "lambda/models/#{@singular_name}.rb"
        write_template('model.rb.erb', dest)
        puts "  create  #{dest}"
      end

      def generate_controller
        dest = "lambda/controllers/#{@app_name}/#{@resource_name}_controller.rb"
        write_template('controller.rb.erb', dest)
        puts "  create  #{dest}"
      end

      def inject_routes
        routes_file = 'infrastructure/routes.tf.rb'
        return unless File.exist?(routes_file)

        content = File.read(routes_file)
        tables_arg = @fields.any? ? ", tables: [:#{@resource_name}]" : ''
        resource_line = "resources :#{@resource_name}#{tables_arg}"

        # Replace the commented placeholder if it exists
        if content.include?('# resources :posts')
          content.sub!('# resources :posts', resource_line)
        else
          # Find the target namespace block and insert before its closing `end`
          # Match: `namespace :<name> do` ... `end` (the first `end` at the same indent level)
          namespace_pattern = /^(\s*)namespace :#{Regexp.escape(@app_name)}\b[^\n]*do\s*\n(.*?)^\1end/m

          if content.match?(namespace_pattern)
            content.sub!(namespace_pattern) do |match|
              indent = $1
              # Insert the resource line before the namespace's closing `end`
              match.sub(/^(#{indent})end\z/m, "#{indent}  #{resource_line}\n#{indent}end")
            end
          else
            # Fallback: find any single namespace block and insert into it
            single_ns_pattern = /^(\s*)namespace :\w+\b[^\n]*do\s*\n(.*?)^\1end/m
            if content.match?(single_ns_pattern)
              content.sub!(single_ns_pattern) do |match|
                indent = $1
                match.sub(/^(#{indent})end\z/m, "#{indent}  #{resource_line}\n#{indent}end")
              end
            else
              # No namespace block found at all — insert at top level before final end
              content.sub!(/^(\s*end\s*)\z/m, "  #{resource_line}\n\\1")
            end
          end
        end

        File.write(routes_file, content)
        puts "  update  #{routes_file}"

        # Also update route manifest
        inject_route_manifest
      end

      def inject_route_manifest
        manifest_file = "lambda/lib/routes/#{@app_name}_routes.rb"
        return unless File.exist?(manifest_file)

        id_param = "#{@singular_name}_id"

        new_routes = [
          "{ verb: 'GET', path: '/#{@resource_name}', controller: '#{@resource_name}', action: 'index' }",
          "{ verb: 'POST', path: '/#{@resource_name}', controller: '#{@resource_name}', action: 'create' }",
          "{ verb: 'GET', path: '/#{@resource_name}/{#{id_param}}', controller: '#{@resource_name}', action: 'show' }",
          "{ verb: 'PUT', path: '/#{@resource_name}/{#{id_param}}', " \
          "controller: '#{@resource_name}', action: 'update' }",
          "{ verb: 'DELETE', path: '/#{@resource_name}/{#{id_param}}', " \
          "controller: '#{@resource_name}', action: 'destroy' }"
        ]

        existing_content = File.read(manifest_file)
        constant = @app_name.upcase

        # Extract existing route entries (preserve routes from other resources)
        existing_routes = existing_content.scan(/\{ verb: .+? \}/)

        # Merge: replace routes for this resource, keep everything else
        other_routes = existing_routes.reject { |r| r.include?("controller: '#{@resource_name}'") }
        all_routes = other_routes + new_routes
        route_lines = all_routes.map { |r| "    #{r}" }.join(",\n")

        content = <<~RUBY
          # frozen_string_literal: true

          module Routes
            #{constant} = [
          #{route_lines}
            ].freeze
          end
        RUBY

        File.write(manifest_file, content)
        puts "  update  #{manifest_file}"
      end

      def inject_schema
        schema_file = 'infrastructure/schema.tf.rb'
        return unless File.exist?(schema_file)

        content = File.read(schema_file)

        field_lines = @fields.map { |f| "    field :#{f[:name]}, type: :#{f[:type]}" }
        field_lines << '    field :created_at, type: :string'
        field_lines << '    field :updated_at, type: :string'

        schema_block = "  model :#{@singular_name} do\n#{field_lines.join("\n")}\n  end\n"

        # Replace commented-out block or insert before final end
        if content.match?(/^\s*#\s*model :/)
          content.gsub!(/^\s*#[^\n]*\n/, '')
          content.sub!(/^(end\s*\z)/m, "#{schema_block}\\1")
        else
          content.sub!(/^(end\s*\z)/m, "\n#{schema_block}\\1")
        end

        File.write(schema_file, content)
        puts "  update  #{schema_file}"
      end

      def write_template(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        FileUtils.mkdir_p(File.dirname(dest_path))
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
      end

      def generate_views_if_frontend
        return unless Dir.exist?('frontend/src')
        return if @skip_views

        Belt::CLI::ViewsCommand.new(@name, @fields).generate
      end
    end
  end
end
