# frozen_string_literal: true

require 'fileutils'
require 'erb'
require 'json'
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

      def initialize(framework)
        @framework = framework
        @app_name = detect_app_name
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
      end

      def generate
        dest_dir = 'frontend'

        if Dir.exist?(dest_dir) && !Dir.empty?(dest_dir)
          puts "Directory 'frontend/' already exists and is not empty."
          exit 1
        end

        puts "Creating #{@framework} frontend application..."
        framework_dir = File.join(TEMPLATE_DIR, @framework)

        unless Dir.exist?(framework_dir)
          puts "✗ Template not found for '#{@framework}'. Available: #{FRAMEWORKS.join(', ')}"
          exit 1
        end

        copy_template(framework_dir, dest_dir)

        puts "\n✓ Frontend (#{@framework}) created in frontend/"

        setup_frontend_infra_for_existing_environments

        puts "\nNext steps:"
        puts '  cd frontend && npm install && npm run dev'
        puts '  belt deploy frontend <env>   # Build and deploy to AWS'
      end

      private

      def setup_frontend_infra_for_existing_environments
        environments = detect_environments
        return if environments.empty?

        puts "\n  Setting up frontend infrastructure for existing environments..."
        require_relative 'frontend_setup_command'

        environments.each do |env_name|
          frontend_tf = "infrastructure/#{env_name}/frontend.tf"
          if File.exist?(frontend_tf)
            puts "  skip    #{frontend_tf} (already exists)"
            next
          end

          FrontendSetupCommand.new(env_name, quiet: true).run
          puts "  create  #{frontend_tf}"
        end
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
          puts "  create  #{dest_path}"
        end
      end
    end
  end
end
