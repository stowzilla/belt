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
      GENERATORS = %w[resource model controller environment frontend views].freeze

      include AppDetection

      def self.run(args)
        generator = args.shift

        if generator.nil? || !GENERATORS.include?(generator)
          puts "Usage: belt generate <#{GENERATORS.join('|')}> <name> [field:type ...]"
          puts "\nExamples:"
          puts '  belt generate resource post title:string content:text status:string'
          puts '  belt generate model comment body:text author:string'
          puts '  belt generate controller comments'
          puts '  belt generate environment dev01'
          exit 1
        end

        return Belt::CLI::EnvironmentCommand.run(args) if generator == 'environment'

        return Belt::CLI::FrontendCommand.run(args) if generator == 'frontend'

        return Belt::CLI::ViewsCommand.run(args) if generator == 'views'

        name = args.shift
        if name.nil? || name.empty?
          puts "Usage: belt generate #{generator} <name> [field:type ...]"
          exit 1
        end

        skip_views = args.delete('--skip-views')
        fields = args.map { |arg| parse_field(arg) }
        new(generator, name, fields, skip_views: skip_views).generate
      end

      def self.parse_field(arg)
        name, type = arg.split(':', 2)
        { name: name, type: type || 'string' }
      end

      def initialize(generator, name, fields, skip_views: false)
        @generator = generator
        @name = name.downcase.gsub(/[^a-z0-9_]/, '_')
        @fields = fields
        @skip_views = skip_views
        @app_name = detect_app_name
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
        @resource_name = @name.end_with?('s') ? @name : "#{@name}s"
        @singular_name = @name.end_with?('s') ? @name.chomp('s') : @name
        @class_name = @singular_name.split('_').map(&:capitalize).join
      end

      def generate
        case @generator
        when 'resource'  then generate_resource
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
        puts "\n✓ Resource '#{@singular_name}' generated!"
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

        # Insert before the closing `end` of the namespace block
        if content.include?('# resources :posts')
          content.sub!('# resources :posts', "resources :#{@resource_name}#{tables_arg}")
        elsif content.match?(/namespace :\w+[^\n]*do\n(\s+#[^\n]*\n)*\s+end/)
          content.sub!(/^(\s+)(end\s*\z)/m, "\\1  resources :#{@resource_name}#{tables_arg}\n\\1\\2")
        else
          content.sub!(/^(\s*end\s*\z)/m, "    resources :#{@resource_name}#{tables_arg}\n\\1")
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
