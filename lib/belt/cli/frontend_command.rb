# frozen_string_literal: true

require 'fileutils'
require 'erb'
require 'json'
require 'open3'
require_relative 'app_detection'
require_relative 'frontend_registry'

module Belt
  module CLI
    class FrontendCommand
      TEMPLATE_DIR = File.expand_path('../../templates/frontend', __dir__)
      FRAMEWORKS = %w[react vue svelte].freeze

      include AppDetection

      def self.run(args)
        name = FrontendRegistry.extract_flag!(args, '--name')
        path = FrontendRegistry.extract_flag!(args, '--path')
        framework = args.shift

        if framework.nil? || !FRAMEWORKS.include?(framework)
          puts "Usage: belt generate frontend <#{FRAMEWORKS.join('|')}> [--name NAME] [--path DIR]"
          puts "\nScaffolds a frontend application with build tooling and API client."
          puts "\nExamples:"
          puts '  belt generate frontend react'
          puts '  belt generate frontend vue'
          puts '  belt generate frontend react --name ops --path ops-app'
          exit 1
        end

        new(framework, name: name, path: path).generate
      end

      def initialize(framework, quiet: false, announce: true, name: nil, path: nil)
        @framework = framework
        @quiet = quiet
        @announce = announce
        @app_name = detect_app_name
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
        @name = name || (path ? File.basename(path) : 'frontend')
        @path = path || name || 'frontend'
        @frontend = Frontend.new(name: @name, path: @path, default: @name == 'frontend' && @path == 'frontend')
      end

      def generate
        dest_dir = @frontend.path

        if Dir.exist?(dest_dir) && !Dir.empty?(dest_dir)
          puts "Directory '#{dest_dir}/' already exists and is not empty."
          exit 1
        end

        puts "Creating #{@framework} frontend application..." unless @quiet
        framework_dir = File.join(TEMPLATE_DIR, @framework)

        unless Dir.exist?(framework_dir)
          puts "✗ Template not found for '#{@framework}'. Available: #{FRAMEWORKS.join(', ')}"
          exit 1
        end

        copy_template(framework_dir, dest_dir)
        register_frontend!

        puts "\n✓ Frontend (#{@framework}) created in #{dest_dir}/" unless @quiet

        install_dependencies(dest_dir)
        setup_frontend_infra_for_existing_environments
        generate_views_for_existing_resources

        return if @quiet || !@announce

        puts "\nNext steps:"
        if @frontend.name == 'frontend'
          puts '  belt server                   # Start local dev server'
        else
          puts "  belt server --frontend #{@frontend.name}"
        end
        puts '  belt deploy                   # Deploy everything to AWS'
      end

      def npm_ok?
        @npm_ok != false
      end

      private

      def install_dependencies(dest_dir)
        puts "\n  Installing npm dependencies..." unless @quiet
        _output, status = Open3.capture2e(
          'npm', 'install', '--prefix', dest_dir, '--no-fund', '--no-audit'
        )
        if status.success?
          puts '  ✓ npm dependencies installed' unless @quiet
          @npm_ok = true
        else
          puts "  ⚠ npm install failed — run `cd #{dest_dir} && npm install` manually" unless @quiet
          @npm_ok = false
        end
      end

      def register_frontend!
        custom = @frontend.name != 'frontend' || @frontend.path != 'frontend'
        config_exists = FrontendRegistry.find_config_path
        return unless custom || config_exists

        dest = FrontendRegistry.register!(name: @frontend.name, path: @frontend.path)
        puts "  update  #{dest} (#{@frontend.name})" unless @quiet
      end

      def setup_frontend_infra_for_existing_environments
        module_dir = 'infrastructure/modules/app'
        frontend_tf = File.join(module_dir, "#{@frontend.tf_name == 'frontend' ? 'frontend' : @frontend.tf_name}.tf")

        if File.exist?(frontend_tf)
          puts "  skip    #{frontend_tf} (already exists)" unless @quiet
          return
        end

        return unless Dir.exist?(module_dir)

        puts "\n  Setting up frontend infrastructure..." unless @quiet
        require_relative 'frontend_setup_command'
        FrontendSetupCommand.new(nil, quiet: true, frontend: @frontend).run
        puts "  create  #{frontend_tf}" unless @quiet
      end

      def generate_views_for_existing_resources
        routes_file = find_routes_file_path
        return unless routes_file && File.exist?(routes_file)

        resources = extract_resources_from_routes(routes_file)
        return if resources.empty?

        puts "\n  Detected existing resources: #{resources.join(', ')}" unless @quiet
        puts '  Generating views...' unless @quiet

        require_relative 'views_command'
        resources.each do |resource_name|
          fields = ViewsCommand.read_schema_fields(resource_name)
          ViewsCommand.new(resource_name, fields, force: true, frontend: @frontend).generate
        end
      end

      def extract_resources_from_routes(routes_file)
        require 'ripper'
        content = File.read(routes_file)
        tokens = Ripper.lex(content)
        resources = []

        tokens.each_cons(3) do |a, b, c|
          # Match: identifier "resources" followed by optional whitespace, then symbol ":name"
          next unless a[1] == :on_ident && a[2] == 'resources'

          # b might be a space or directly the symbol prefix
          sym_token = b[1] == :on_sp ? c : b
          next unless sym_token[1] == :on_symbeg && sym_token[2] == ':'

          # The symbol name is the next token
          sym_idx = tokens.index(sym_token)
          name_token = tokens[sym_idx + 1]
          resources << name_token[2] if name_token && name_token[1] == :on_ident
        end

        resources.uniq
      end

      def copy_template(src_dir, dest_dir)
        Dir.glob("#{src_dir}/**/*", File::FNM_DOTMATCH).each do |src|
          next if File.directory?(src)
          next if src.end_with?('/..') || src.end_with?('/.')

          rel_path = src.sub("#{src_dir}/", '')
          dest_path = File.join(dest_dir, rel_path.sub(/\.erb\z/, ''))

          FileUtils.mkdir_p(File.dirname(dest_path))

          if src.end_with?('.erb')
            content = ERB.new(File.read(src), trim_mode: '-').result(binding)
            File.write(dest_path, content)
          else
            FileUtils.cp(src, dest_path)
          end
          puts "  create  #{dest_path}" unless @quiet
        end
      end
    end
  end
end
