# frozen_string_literal: true

require 'fileutils'
require 'erb'

module Belt
  module CLI
    class NewCommand
      TEMPLATE_DIR = File.expand_path('../../templates/new_app', __dir__)

      def self.run(args)
        app_name = nil
        frontend = nil

        args.each do |arg|
          if arg.start_with?('--frontend')
            frontend = if arg.include?('=')
                         arg.split('=', 2).last
                       else
                         args[args.index(arg) + 1]
                       end
          elsif !arg.start_with?('-')
            app_name ||= arg
          end
        end

        if app_name.nil? || app_name.empty?
          puts 'Usage: belt new <app_name> [--frontend react|vue|svelte]'
          exit 1
        end

        new(app_name, frontend: frontend).generate
      end

      def initialize(app_name, frontend: nil)
        @app_name = app_name.gsub(/[^a-z0-9_-]/i, '_').downcase
        @module_name = @app_name.split(/[-_]/).map(&:capitalize).join
        @frontend = frontend
      end

      def generate
        if Dir.exist?(@app_name)
          puts "Directory '#{@app_name}' already exists."
          exit 1
        end

        puts "Creating new Belt application: #{@app_name}"
        create_structure
        generate_frontend if @frontend
        init_git
        puts "\n✓ #{@app_name} created successfully!"
        puts "\nNext steps:"
        puts "  cd #{@app_name}"
        puts '  bundle install'
        puts '  cd frontend && npm install && npm run dev' if @frontend
        puts '  # Define your models in infrastructure/schema.tf.rb'
        puts '  # Define your routes in infrastructure/routes.tf.rb'
        puts "  # Add controllers in lambda/controllers/#{@app_name}/"
      end

      private

      def create_structure
        directories.each { |dir| create_dir(dir) }
        files.each { |src, dest| create_file(src, dest) }
      end

      def directories
        %W[
          #{@app_name}/lambda/controllers/#{@app_name}
          #{@app_name}/lambda/models
          #{@app_name}/lambda/models/concerns
          #{@app_name}/lambda/lib/routes
          #{@app_name}/lambda/spec
          #{@app_name}/infrastructure
        ]
      end

      def files
        {
          'Gemfile.erb' => "#{@app_name}/Gemfile",
          'lambda/Gemfile.erb' => "#{@app_name}/lambda/Gemfile",
          'lambda/api.rb.erb' => "#{@app_name}/lambda/#{@app_name}.rb",
          'lambda/models/application_record.rb.erb' => "#{@app_name}/lambda/models/application_record.rb",
          'lambda/models/concerns/timestampable.rb.erb' => "#{@app_name}/lambda/models/concerns/timestampable.rb",
          'lambda/controllers/application_controller.rb.erb' =>
            "#{@app_name}/lambda/controllers/#{@app_name}/application_controller.rb",
          'lambda/lib/routes/routes.rb.erb' => "#{@app_name}/lambda/lib/routes/#{@app_name}_routes.rb",
          'infrastructure/routes.tf.rb.erb' => "#{@app_name}/infrastructure/routes.tf.rb",
          'infrastructure/schema.tf.rb.erb' => "#{@app_name}/infrastructure/schema.tf.rb",
          'README.md.erb' => "#{@app_name}/README.md",
          'AGENTS.md.erb' => "#{@app_name}/AGENTS.md",
          'gitignore.erb' => "#{@app_name}/.gitignore"
        }
      end

      def create_dir(dir)
        FileUtils.mkdir_p(dir)
        puts "  create  #{dir}/"
      end

      def create_file(template_name, dest_path)
        template_path = File.join(TEMPLATE_DIR, template_name)
        content = ERB.new(File.read(template_path), trim_mode: '-').result(binding)
        File.write(dest_path, content)
        puts "  create  #{dest_path}"
      end

      def init_git
        Dir.chdir(@app_name) do
          system('git', 'init', '--quiet')
          system('git', 'add', '.')
          system('git', 'commit', '-m', 'Initial commit', '--quiet')
        end
        puts "  init    #{@app_name}/.git/"
      end

      def generate_frontend
        Dir.chdir(@app_name) do
          Belt::CLI::FrontendCommand.new(@frontend).generate
        end
      end
    end
  end
end
