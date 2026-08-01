# frozen_string_literal: true

require 'fileutils'
require 'erb'
require_relative '../inflector'

module Belt
  module CLI
    class ViewsCommand
      TEMPLATE_DIR = File.expand_path('../../templates/views', __dir__)

      def self.run(args)
        force = args.delete('--force') || args.delete('-f')

        name = args.shift
        if name.nil? || name.empty?
          puts 'Usage: belt generate views <resource> [field:type ...] [options]'
          puts "\nGenerates React pages for all REST actions (index, show, new, edit)."
          puts "\nOptions:"
          puts '  --force, -f    Overwrite existing files without prompting'
          puts "\nExamples:"
          puts '  belt generate views post title:string content:text status:string'
          puts '  belt generate views comment body:text author:string'
          exit 1
        end

        fields = args.map do |arg|
          n, t = arg.split(':', 2)
          { name: n, type: t || 'string' }
        end

        # If no fields provided, try to read from contracts.rb
        fields = read_schema_fields(name) if fields.empty?

        new(name, fields, force: force).generate
      end

      def self.read_schema_fields(name)
        schema_file = [
          'config/contracts.rb',
          'config/contracts.tf.rb',
          'config/schema.tf.rb',
          'infrastructure/schema.tf.rb'
        ].find { |f| File.exist?(f) }
        return [] unless schema_file

        content = File.read(schema_file)
        singular = Belt::Inflector.singularize(name)

        # Extract fields from model block
        if content =~ /model :#{singular} do\n(.*?)\n\s*end/m
          block_content = ::Regexp.last_match(1)
          timestamp_fields = %w[created_at updated_at]

          # Support both formats:
          #   field :name, type: :string   (legacy)
          #   string :name                 (current schema DSL)
          dsl_types = %w[string text integer number boolean float date datetime]
          dsl_pattern = /(?:#{dsl_types.join('|')}) :(\w+)/
          fields = block_content.scan(/field :(\w+), type: :(\w+)/)
          fields += block_content.scan(dsl_pattern).map do |match|
            field_name = match[0]
            # Extract type from the DSL method name on that line
            type_match = block_content.match(/(\w+) :#{Regexp.escape(field_name)}/)
            [field_name, type_match ? type_match[1] : 'string']
          end

          fields.filter_map do |n, t|
            next if timestamp_fields.include?(n)

            { name: n, type: t }
          end
        else
          []
        end
      end

      def initialize(name, fields, force: false)
        @name = name.downcase.gsub(/[^a-z0-9_]/, '_')
        @fields = fields
        @force = force
        @overwrite_all = false
        @singular_name = Belt::Inflector.singularize(@name)
        @resource_name = Belt::Inflector.pluralize(@singular_name)
        @class_name = Belt::Inflector.classify(@singular_name)
      end

      def generate
        unless Dir.exist?('frontend/src')
          puts '✗ No frontend/ directory found. Run `belt generate frontend react` first.'
          exit 1
        end

        pages_dir = "frontend/src/pages/#{@resource_name}"
        @plural_class_name = Belt::Inflector.camelize(@resource_name)
        FileUtils.mkdir_p(pages_dir)

        write_template('Index.jsx.erb', "#{pages_dir}/#{@plural_class_name}Index.jsx")
        write_template('Show.jsx.erb', "#{pages_dir}/#{@class_name}Show.jsx")
        write_template('New.jsx.erb', "#{pages_dir}/#{@class_name}New.jsx")
        write_template('Edit.jsx.erb', "#{pages_dir}/#{@class_name}Edit.jsx")
        write_template('Form.jsx.erb', "#{pages_dir}/#{@class_name}Form.jsx")

        inject_routes

        puts "\n✓ Views for '#{@singular_name}' generated!"
        puts "\nFiles created:"
        puts "  #{pages_dir}/#{@plural_class_name}Index.jsx"
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
        existed = File.exist?(dest_path)

        if existed && !@force && !@overwrite_all
          action = prompt_overwrite(dest_path)
          case action
          when :yes
            # fall through to write
          when :all
            @overwrite_all = true
            # fall through to write
          when :no
            puts "  skip    #{dest_path}"
            return
          when :quit
            puts "\nAborted."
            exit 1
          end
        end

        File.write(dest_path, content)
        puts "  #{existed ? 'overwrite' : 'create'}  #{dest_path}"
      end

      def prompt_overwrite(path)
        return :yes if @overwrite_all

        print "  conflict  #{path}\n"
        print "  Overwrite #{path}? (enter \"h\" for help) [Ynaqh] "
        $stdout.flush

        loop do
          answer = $stdin.gets&.strip&.downcase
          case answer
          when '', 'y', 'yes'
            return :yes
          when 'n', 'no'
            return :no
          when 'a', 'all'
            @overwrite_all = true
            return :all
          when 'q', 'quit'
            return :quit
          when 'h', 'help'
            puts '  Y - yes, overwrite this file'
            puts '  n - no, skip this file'
            puts '  a - all, overwrite this and all remaining files'
            puts '  q - quit, abort the generator'
            puts '  h - help, show this help'
            print "  Overwrite #{path}? (enter \"h\" for help) [Ynaqh] "
            $stdout.flush
          else
            print '  Please enter Y, n, a, q, or h: '
            $stdout.flush
          end
        end
      end

      def inject_routes
        app_jsx = 'frontend/src/App.jsx'
        return unless File.exist?(app_jsx)

        content = File.read(app_jsx)
        pages_dir = @resource_name
        plural_class = @plural_class_name || Belt::Inflector.camelize(@resource_name)

        # Skip route injection if routes for this resource already exist
        if content.include?("path=\"/#{@resource_name}\"")
          puts "  skip    #{app_jsx} (routes already exist)"
          return
        end

        import_lines = [
          "import #{plural_class}Index from './pages/#{pages_dir}/#{plural_class}Index'",
          "import #{@class_name}Show from './pages/#{pages_dir}/#{@class_name}Show'",
          "import #{@class_name}New from './pages/#{pages_dir}/#{@class_name}New'",
          "import #{@class_name}Edit from './pages/#{pages_dir}/#{@class_name}Edit'"
        ]

        route_lines = [
          "        <Route path=\"/#{@resource_name}\" element={<#{plural_class}Index />} />",
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
