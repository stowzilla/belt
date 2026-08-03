# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative 'app_detection'
require_relative 'environment_command'
require_relative 'frontend_command'
require_relative 'tables_command'
require_relative 'views_command'
require_relative 'generator_registry'
require_relative '../inflector'

module Belt
  module CLI
    class GenerateCommand
      TEMPLATE_DIR = File.expand_path('../../templates/generate', __dir__)
      GENERATORS = %w[scaffold resource model controller environment frontend views].freeze

      include AppDetection

      FIELD_TYPES = %w[string text integer float boolean date datetime references].freeze

      GENERATOR_HELP = {
        'scaffold' => {
          description: 'Generate a model, controller, routes, schema, and views for a REST resource.',
          usage: 'belt generate scaffold <name> [field:type ...] [options]',
          options: [
            ['--skip-views', 'Skip generating frontend view pages'],
            ['--force, -f', 'Overwrite existing resource files (skip collision check)']
          ],
          examples: [
            ['belt g scaffold post title body:text'],
            ['belt g scaffold comment post:references body:text'],
            ['belt g scaffold task --skip-views'],
            ['belt g scaffold post title body:text --force']
          ],
          notes: <<~NOTES
            Creates:
              lambda/models/<name>.rb                            Model with validations and fields
              lambda/controllers/<app>/<names>_controller.rb    RESTful controller (index, show, create, update, destroy)
              config/routes.rb                                   Route entry added
              config/contracts.rb                                API response contract added
              lambda/lib/routes/<app>_routes.rb                  Route manifest updated
              infrastructure/modules/app/dynamodb.tf             DynamoDB table generated
              frontend/src/pages/<names>/                        React pages (if frontend exists)

            Nested Resources:
              Use `<parent>:references` to create a nested resource. This will:
              - Add `belongs_to :<parent>` in the child model
              - Add `has_many :<children>` in the parent model (if it exists)
              - Generate a GSI on `<parent>_id` for efficient queries
              - Nest routes under the parent (e.g., /posts/{post_id}/comments)
              - Scope the controller index action to the parent

              Example: `belt g scaffold comment post:references body:text`

            Alias: `belt g resource` works the same way.
          NOTES
        },
        'model' => {
          description: 'Generate an ActiveItem model with validations and DynamoDB field definitions.',
          usage: 'belt generate model <name> [field:type ...] [options]',
          options: [
            ['--force, -f', 'Overwrite existing model files (skip collision check)']
          ],
          examples: [
            ['belt g model user email name'],
            ['belt g model event title starts_at:datetime']
          ],
          notes: <<~NOTES
            Creates:
              lambda/models/<name>.rb                            Model class inheriting from ApplicationRecord
              config/contracts.rb                                API response contract added
              infrastructure/modules/app/dynamodb.tf             DynamoDB table generated
          NOTES
        },
        'controller' => {
          description: 'Generate a controller with standard REST actions.',
          usage: 'belt generate controller <name>',
          options: [],
          examples: [
            ['belt g controller posts'],
            ['belt g controller admin/users']
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

        unless GENERATORS.include?(generator) || GeneratorRegistry.generator_names.include?(generator)
          puts "Unknown generator: '#{generator}'"
          puts "Available generators: #{all_generator_names.join(', ')}"
          puts "\nRun 'belt generate --help' for usage information."
          exit 1
        end

        # Delegate to gem-provided generator if not a built-in
        unless GENERATORS.include?(generator)
          klass = GeneratorRegistry.find(generator)
          return klass.run(args)
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

        force = args.delete('--force') || args.delete('-f')
        skip_views = args.delete('--skip-views')
        fields = args.map { |arg| parse_field(arg) }
        new(generator, name, fields, skip_views: skip_views, force: force).generate
      end

      def self.parse_field(arg)
        name, type = arg.split(':', 2)
        type ||= 'string'

        if %w[references belongs_to].include?(type)
          { name: name, type: 'references', referenced_model: name }
        else
          { name: name, type: type }
        end
      end

      RESERVED_NAMES = %w[
        help new edit create update destroy index show delete remove
        application base controller model resource generate
        belt setup environment frontend views routes
      ].freeze

      def self.all_generator_names
        ((GENERATORS - ['resource']) + GeneratorRegistry.generator_names).uniq
      end

      def self.validate_resource_name!(name, generator)
        errors = []

        errors << 'must start with a letter' unless name.match?(/\A[a-zA-Z]/)
        errors << 'must be at least 2 characters' if name.length < 2
        errors << 'must only contain letters, numbers, and underscores' unless name.match?(/\A[a-zA-Z][a-zA-Z0-9_]*\z/)
        errors << 'must not start or end with an underscore' if name.match?(/\A_|_\z/)
        errors << 'must not contain consecutive underscores' if name.include?('__')
        errors << 'is a reserved name' if RESERVED_NAMES.include?(Belt::Inflector.singularize(name.downcase))
        errors << 'is a reserved name' if RESERVED_NAMES.include?(name.downcase)

        return if errors.empty?

        puts "\n✗ Invalid #{generator} name '#{name}':"
        errors.uniq.each { |e| puts "  - #{e}" }
        puts "\nName must start with a letter, be at least 2 characters, " \
             'and contain only letters, numbers, and single underscores.'
        exit 1
      end

      def self.print_generate_help
        gem_generators = GeneratorRegistry.discovered_generators

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

        HELP

        if gem_generators.any?
          puts '  Gem Generators:'
          gem_generators.each do |name, klass|
            desc = klass.respond_to?(:description) ? klass.description : "Generate #{name} (from gem)"
            puts format('    %<name>-14s %<desc>s', name: name, desc: desc)
          end
          puts
        end

        puts <<~HELP
          Field Types:
            #{FIELD_TYPES.join(', ')}
            (defaults to string if omitted)

          Examples:
            belt g scaffold post title body:text status
            belt g model user email name
            belt g controller comments
            belt g environment staging
            belt g frontend react
            belt g views post title body:text

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
            puts format('  %<flag>-20s %<desc>s', flag: flag, desc: desc)
          end
        end

        puts "\nField Types:"
        puts "  #{FIELD_TYPES.join(', ')}"
        puts '  (defaults to string if omitted)'

        puts "\nExamples:"
        info[:examples].each do |cmd, desc|
          if desc
            puts "  #{cmd}  — #{desc}"
          else
            puts "  #{cmd}"
          end
        end

        puts "\n#{info[:notes]}" if info[:notes]
      end

      def initialize(generator, name, fields, skip_views: false, force: false)
        @generator = generator
        @name = name.downcase.gsub(/[^a-z0-9_]/, '_')
        @fields = fields
        @skip_views = skip_views
        @force = force
        @app_name = detect_namespace
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
        @singular_name = Belt::Inflector.singularize(@name)
        @resource_name = Belt::Inflector.pluralize(@singular_name)
        @class_name = Belt::Inflector.classify(@singular_name)
        @references, @regular_fields = @fields.partition { |f| f[:type] == 'references' }
      end

      def generate
        case @generator
        when 'scaffold'
          check_resource_collision! unless @force
          generate_resource
        when 'model'
          check_model_collision! unless @force
          generate_model_standalone
        when 'controller' then generate_controller
        end
      end

      private

      def check_resource_collision!
        conflicts = []
        conflicts << "lambda/models/#{@singular_name}.rb" if File.exist?("lambda/models/#{@singular_name}.rb")
        if File.exist?("lambda/controllers/#{@app_name}/#{@resource_name}_controller.rb")
          conflicts << "lambda/controllers/#{@app_name}/#{@resource_name}_controller.rb"
        end

        schema_file = find_schema_file_path
        if schema_file && File.exist?(schema_file) &&
           File.read(schema_file).match?(/^\s*model :#{Regexp.escape(@singular_name)}\b/)
          conflicts << "#{schema_file} (model :#{@singular_name})"
        end

        routes_file = find_routes_file_path
        if routes_file && File.exist?(routes_file) &&
           File.read(routes_file).match?(/resources :#{Regexp.escape(@resource_name)}\b/)
          conflicts << "#{routes_file} (resources :#{@resource_name})"
        end

        return if conflicts.empty?

        puts "\n✗ Resource '#{@singular_name}' already exists. Conflicting files:"
        conflicts.each { |c| puts "    • #{c}" }
        puts "\nTo overwrite, run again with --force:"
        puts "  belt g scaffold #{@singular_name} #{@fields.map { |f| "#{f[:name]}:#{f[:type]}" }.join(' ')} --force"
        exit 1
      end

      def check_model_collision!
        conflicts = []
        conflicts << "lambda/models/#{@singular_name}.rb" if File.exist?("lambda/models/#{@singular_name}.rb")

        schema_file = find_schema_file_path
        if schema_file && File.exist?(schema_file) &&
           File.read(schema_file).match?(/^\s*model :#{Regexp.escape(@singular_name)}\b/)
          conflicts << "#{schema_file} (model :#{@singular_name})"
        end

        return if conflicts.empty?

        puts "\n✗ Model '#{@singular_name}' already exists. Conflicting files:"
        conflicts.each { |c| puts "    • #{c}" }
        puts "\nTo overwrite, run again with --force:"
        puts "  belt g model #{@singular_name} #{@fields.map { |f| "#{f[:name]}:#{f[:type]}" }.join(' ')} --force"
        exit 1
      end

      def generate_resource
        generate_model
        generate_controller
        inject_routes
        inject_schema
        inject_parent_associations
        sync_tables
        generate_views_if_frontend
      end

      def generate_model_standalone
        generate_model
        inject_schema
        inject_parent_associations
        sync_tables
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
        routes_file = find_routes_file_path
        return unless routes_file && File.exist?(routes_file)

        content = File.read(routes_file)
        tables_arg = @fields.any? ? ", tables: [:#{@resource_name}]" : ''

        # If this resource has a reference to a parent that already has routes, nest it
        parent_ref = @references.find do |ref|
          parent_resource = Belt::Inflector.pluralize(ref[:referenced_model])
          content.match?(/resources :#{Regexp.escape(parent_resource)}\b/)
        end

        if parent_ref
          inject_nested_route(content, routes_file, parent_ref, tables_arg)
        else
          inject_top_level_route(content, routes_file, tables_arg)
        end

        # Also update route manifest
        inject_route_manifest
      end

      def inject_nested_route(content, routes_file, parent_ref, tables_arg)
        parent_resource = Belt::Inflector.pluralize(parent_ref[:referenced_model])
        resource_line = "resources :#{@resource_name}#{tables_arg}"

        # Find the parent resources line and convert to a block if needed
        parent_pattern = /^(\s*)resources :#{Regexp.escape(parent_resource)}\b([^\n]*?)(?:\s*do\s*)?$/

        if content.match?(/resources :#{Regexp.escape(parent_resource)}\b[^\n]*\bdo\b/)
          # Parent already has a block — insert before its closing end
          # Match the parent block: resources :parent do ... end
          block_pattern = /^(\s*)(resources :#{Regexp.escape(parent_resource)}\b[^\n]*do\s*\n)(.*?)^\1(end)/m
          if content.match?(block_pattern)
            content.sub!(block_pattern) do
              indent = ::Regexp.last_match(1)
              opener = ::Regexp.last_match(2)
              body = ::Regexp.last_match(3)
              closer = ::Regexp.last_match(4)
              "#{indent}#{opener}#{body}#{indent}  #{resource_line}\n#{indent}#{closer}"
            end
          end
        else
          # Parent is a single line — convert to block form
          content.sub!(parent_pattern) do
            indent = ::Regexp.last_match(1)
            parent_line_rest = ::Regexp.last_match(2).rstrip
            "#{indent}resources :#{parent_resource}#{parent_line_rest} do\n" \
              "#{indent}  #{resource_line}\n" \
              "#{indent}end"
          end
        end

        File.write(routes_file, content)
        puts "  update  #{routes_file}"
      end

      def inject_top_level_route(content, routes_file, tables_arg)
        resource_line = "resources :#{@resource_name}#{tables_arg}"

        # If this resource already exists in routes (force mode), replace it
        existing_resource_pattern = /^\s*resources :#{Regexp.escape(@resource_name)}\b[^\n]*/
        if content.match?(existing_resource_pattern)
          content.sub!(existing_resource_pattern) do |match|
            indent = match[/^\s*/]
            "#{indent}#{resource_line}"
          end
        # Replace the commented placeholder if it exists
        elsif content.include?('# resources :posts')
          content.sub!('# resources :posts', resource_line)
        else
          # Find the target namespace block and insert before its closing `end`
          namespace_pattern = /^(\s*)namespace :#{Regexp.escape(@app_name)}\b[^\n]*do\s*\n(.*?)^\1end/m

          if content.match?(namespace_pattern)
            content.sub!(namespace_pattern) do |match|
              indent = ::Regexp.last_match(1)
              match.sub(/^(#{indent})end\z/m, "#{indent}  #{resource_line}\n#{indent}end")
            end
          else
            single_ns_pattern = /^(\s*)namespace :\w+\b[^\n]*do\s*\n(.*?)^\1end/m
            if content.match?(single_ns_pattern)
              content.sub!(single_ns_pattern) do |match|
                indent = ::Regexp.last_match(1)
                match.sub(/^(#{indent})end\z/m, "#{indent}  #{resource_line}\n#{indent}end")
              end
            else
              content.sub!(/^(\s*end\s*)\z/m, "  #{resource_line}\n\\1")
            end
          end
        end

        File.write(routes_file, content)
        puts "  update  #{routes_file}"
      end

      def inject_route_manifest
        manifest_file = "lambda/lib/routes/#{@app_name}_routes.rb"
        return unless File.exist?(manifest_file)

        id_param = "#{@singular_name}_id"

        # Determine if this is nested under a parent
        parent_ref = @references.first
        if parent_ref
          parent_resource = Belt::Inflector.pluralize(parent_ref[:referenced_model])
          parent_singular = parent_ref[:referenced_model]
          parent_id_param = "#{parent_singular}_id"
          path_prefix = "/#{parent_resource}/{#{parent_id_param}}"

          new_routes = [
            "{ verb: 'GET', path: '#{path_prefix}/#{@resource_name}', " \
            "controller: '#{@resource_name}', action: 'index' }",
            "{ verb: 'POST', path: '#{path_prefix}/#{@resource_name}', " \
            "controller: '#{@resource_name}', action: 'create' }",
            "{ verb: 'GET', path: '#{path_prefix}/#{@resource_name}/{#{id_param}}', " \
            "controller: '#{@resource_name}', action: 'show' }",
            "{ verb: 'PUT', path: '#{path_prefix}/#{@resource_name}/{#{id_param}}', " \
            "controller: '#{@resource_name}', action: 'update' }",
            "{ verb: 'DELETE', path: '#{path_prefix}/#{@resource_name}/{#{id_param}}', " \
            "controller: '#{@resource_name}', action: 'destroy' }"
          ]
        else
          new_routes = [
            "{ verb: 'GET', path: '/#{@resource_name}', controller: '#{@resource_name}', action: 'index' }",
            "{ verb: 'POST', path: '/#{@resource_name}', controller: '#{@resource_name}', action: 'create' }",
            "{ verb: 'GET', path: '/#{@resource_name}/{#{id_param}}', " \
            "controller: '#{@resource_name}', action: 'show' }",
            "{ verb: 'PUT', path: '/#{@resource_name}/{#{id_param}}', " \
            "controller: '#{@resource_name}', action: 'update' }",
            "{ verb: 'DELETE', path: '/#{@resource_name}/{#{id_param}}', " \
            "controller: '#{@resource_name}', action: 'destroy' }"
          ]
        end

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
        schema_file = find_schema_file_path
        return unless schema_file && File.exist?(schema_file)

        content = File.read(schema_file)

        # Generate OpenAPI-style model block for API response contracts
        response_fields = @references.map { |ref| "    string :#{ref[:referenced_model]}_id" }
        response_fields += @regular_fields.map { |f| "    #{schema_type_for(f[:type])} :#{f[:name]}" }
        response_fields << '    string :created_at'
        response_fields << '    string :updated_at'

        schema_block = "  model :#{@singular_name} do\n#{response_fields.join("\n")}\n  end\n"

        # If model already exists (force mode), replace it
        existing_model_pattern = /^  model :#{Regexp.escape(@singular_name)} do\n.*?^  end\n/m
        if content.match?(existing_model_pattern)
          content.sub!(existing_model_pattern, schema_block)
        # Replace commented-out block or insert before final end
        elsif content.match?(/^\s*#\s*model :/)
          content.gsub!(/^\s*#[^\n]*\n/, '')
          content.sub!(/^(end\s*\z)/m, "#{schema_block}\\1")
        else
          content.sub!(/^(end\s*\z)/m, "\n#{schema_block}\\1")
        end

        File.write(schema_file, content)
        puts "  update  #{schema_file}"
      end

      # Map generator field types to schema DSL types.
      # Preserves :text, :date, :datetime so views can render appropriate form inputs.
      def schema_type_for(field_type)
        case field_type.to_s
        when 'text' then 'text'
        when 'integer' then 'integer'
        when 'float' then 'number'
        when 'boolean' then 'boolean'
        when 'date' then 'date'
        when 'datetime' then 'datetime'
        when 'references' then 'string'
        else 'string'
        end
      end

      def inject_parent_associations
        @references.each do |ref|
          parent_model_path = "lambda/models/#{ref[:referenced_model]}.rb"
          next unless File.exist?(parent_model_path)

          content = File.read(parent_model_path)
          has_many_line = "  has_many :#{@resource_name}, foreign_key: '#{ref[:referenced_model]}_id', " \
                          "index: '#{Belt::Inflector.classify(ref[:referenced_model])}Index'"

          next if content.include?("has_many :#{@resource_name}")

          # Insert after the last belongs_to/has_many line, or after class declaration
          if content.match?(/^\s*(has_many|belongs_to)\s+:/)
            content.sub!(/^(\s*(?:has_many|belongs_to)\s+:[^\n]+\n)(?!.*(?:has_many|belongs_to))/m) do |match|
              "#{match}#{has_many_line}\n"
            end
          elsif content.match?(/^class\s+\w+\s*<\s*\w+/)
            content.sub!(/^(class\s+\w+\s*<\s*\w+.*\n)/) do |match|
              "#{match}#{has_many_line}\n\n"
            end
          end

          File.write(parent_model_path, content)
          puts "  update  #{parent_model_path} (added has_many :#{@resource_name})"
        end
      end

      def sync_tables
        Belt::CLI::TablesCommand.sync_all_environments
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

        Belt::CLI::ViewsCommand.new(@name, @fields, force: @force, quiet: true).generate
      end
    end
  end
end
