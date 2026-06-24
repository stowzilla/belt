# frozen_string_literal: true

require 'fileutils'
require 'erb'

module Belt
  module CLI
    class ViewsCommand
      TEMPLATE_DIR = File.expand_path('../../templates/views', __dir__)

      def self.run(args)
        name = args.shift
        if name.nil? || name.empty?
          puts 'Usage: belt generate views <resource> [field:type ...]'
          puts "\nGenerates React pages for all REST actions (index, show, new, edit)."
          puts "\nExamples:"
          puts '  belt generate views post title:string content:text status:string'
          puts '  belt generate views comment body:text author:string'
          exit 1
        end

        fields = args.map do |arg|
          n, t = arg.split(':', 2)
          { name: n, type: t || 'string' }
        end

        # If no fields provided, try to read from schema.tf.rb
        fields = read_schema_fields(name) if fields.empty?

        new(name, fields).generate
      end

      def self.read_schema_fields(name)
        schema_file = 'infrastructure/schema.tf.rb'
        return [] unless File.exist?(schema_file)

        content = File.read(schema_file)
        singular = name.end_with?('s') ? name.chomp('s') : name

        # Extract fields from model block
        if content =~ /model :#{singular} do\n(.*?)\n\s*end/m
          ::Regexp.last_match(1).scan(/field :(\w+), type: :(\w+)/).except('created_at', 'updated_at')
                  .map do |n, t|
            {
              name: n, type: t
            }
          end
        else
          []
        end
      end

      def initialize(name, fields)
        @name = name.downcase.gsub(/[^a-z0-9_]/, '_')
        @fields = fields
        @resource_name = @name.end_with?('s') ? @name : "#{@name}s"
        @singular_name = @name.end_with?('s') ? @name.chomp('s') : @name
        @class_name = @singular_name.split('_').map(&:capitalize).join
      end

      def generate
        unless Dir.exist?('frontend/src')
          puts '✗ No frontend/ directory found. Run `belt generate frontend react` first.'
          exit 1
        end

        pages_dir = "frontend/src/pages/#{@resource_name}"
        FileUtils.mkdir_p(pages_dir)

        write_template('Index.jsx.erb', "#{pages_dir}/#{@class_name}sIndex.jsx")
        write_template('Show.jsx.erb', "#{pages_dir}/#{@class_name}Show.jsx")
        write_template('New.jsx.erb', "#{pages_dir}/#{@class_name}New.jsx")
        write_template('Edit.jsx.erb', "#{pages_dir}/#{@class_name}Edit.jsx")
        write_template('Form.jsx.erb', "#{pages_dir}/#{@class_name}Form.jsx")

        inject_routes

        puts "\n✓ Views for '#{@singular_name}' generated!"
        puts "\nFiles created:"
        puts "  #{pages_dir}/#{@class_name}sIndex.jsx"
        puts "  #{pages_dir}/#{@class_name}Show.jsx"
        puts "  #{pages_dir}/#{@class_name}New.jsx"
        puts "  #{pages_dir}/#{@class_name}Edit.jsx"
        puts "  #{pages_dir}/#{@class_name}Form.jsx"
        puts '  frontend/src/App.jsx (updated)'
      end

      private

      def write_template(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
        puts "  create  #{dest_path}"
      end

      def inject_routes
        app_jsx = 'frontend/src/App.jsx'
        return unless File.exist?(app_jsx)

        content = File.read(app_jsx)
        pages_dir = @resource_name

        import_lines = [
          "import #{@class_name}sIndex from './pages/#{pages_dir}/#{@class_name}sIndex'",
          "import #{@class_name}Show from './pages/#{pages_dir}/#{@class_name}Show'",
          "import #{@class_name}New from './pages/#{pages_dir}/#{@class_name}New'",
          "import #{@class_name}Edit from './pages/#{pages_dir}/#{@class_name}Edit'"
        ]

        route_lines = [
          "        <Route path=\"/#{@resource_name}\" element={<#{@class_name}sIndex />} />",
          "        <Route path=\"/#{@resource_name}/new\" element={<#{@class_name}New />} />",
          "        <Route path=\"/#{@resource_name}/:id\" element={<#{@class_name}Show />} />",
          "        <Route path=\"/#{@resource_name}/:id/edit\" element={<#{@class_name}Edit />} />"
        ]

        # Add imports after last import line
        last_import_idx = content.rindex(/^import .+$/)
        if last_import_idx
          end_of_line = content.index("\n", last_import_idx)
          content.insert(end_of_line, "\n#{import_lines.join("\n")}")
        end

        # Add routes before closing </Routes> (no regex — avoids polynomial backtracking)
        close_idx = content.index('</Routes>')
        content.insert(close_idx, "#{route_lines.join("\n")}\n") if close_idx

        File.write(app_jsx, content)
        puts "  update  #{app_jsx}"
      end
    end
  end
end
