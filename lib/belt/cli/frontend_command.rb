# frozen_string_literal: true

require 'fileutils'
require 'erb'
require 'json'
require 'open3'
require_relative 'app_detection'

module Belt
  module CLI
    class FrontendCommand
      TEMPLATE_DIR = File.expand_path('../../templates/frontend', __dir__)
      FRAMEWORKS = %w[react vue svelte].freeze

      include AppDetection

      def self.run(args)
        framework = args.shift

        if framework.nil? || !FRAMEWORKS.include?(framework)
          puts "Usage: belt generate frontend <#{FRAMEWORKS.join('|')}>"
          puts "\nScaffolds a frontend application with build tooling and API client."
          puts "\nExamples:"
          puts '  belt generate frontend react'
          puts '  belt generate frontend vue'
          exit 1
        end

        new(framework).generate
      end

      def initialize(framework, quiet: false)
        @framework = framework
        @quiet = quiet
        @app_name = detect_app_name
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
      end

      def generate
        dest_dir = 'frontend'

        if Dir.exist?(dest_dir) && !Dir.empty?(dest_dir)
          puts "Directory 'frontend/' already exists and is not empty."
          exit 1
        end

        puts "Creating #{@framework} frontend application..." unless @quiet
        framework_dir = File.join(TEMPLATE_DIR, @framework)

        unless Dir.exist?(framework_dir)
          puts "✗ Template not found for '#{@framework}'. Available: #{FRAMEWORKS.join(', ')}"
          exit 1
        end

        copy_template(framework_dir, dest_dir)

        puts "\n✓ Frontend (#{@framework}) created in frontend/" unless @quiet

        @npm_ok = install_dependencies(dest_dir)
        setup_frontend_infra_for_existing_environments

        return if @quiet

        puts "\nNext steps:"
        puts '  belt server                   # Start local dev server'
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
          true
        else
          unless @quiet
            puts "  ⚠ npm install failed — run `cd #{dest_dir} && npm install` manually"
          end
          false
        end
      end

      def setup_frontend_infra_for_existing_environments
        module_dir = 'infrastructure/modules/app'
        frontend_tf = File.join(module_dir, 'frontend.tf')

        if File.exist?(frontend_tf)
          puts "  skip    #{frontend_tf} (already exists)" unless @quiet
          return
        end

        return unless Dir.exist?(module_dir)

        puts "\n  Setting up frontend infrastructure..." unless @quiet
        require_relative 'frontend_setup_command'
        FrontendSetupCommand.new(nil, quiet: true).run
        puts "  create  #{frontend_tf}" unless @quiet
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
