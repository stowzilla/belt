# frozen_string_literal: true

require 'fileutils'
require 'erb'

module Belt
  module CLI
    # Scaffold a new Belt plugin gem (similar to `rails plugin new`).
    #
    # Usage:
    #   belt plugin new messaging
    #   belt plugin new belt-pay --path ~/code
    #
    # Creates a gem that registers with Belt's GeneratorRegistry via:
    #   lib/belt/generators/<name>_generator.rb
    class PluginCommand
      TEMPLATE_DIR = File.expand_path('../../templates/plugin', __dir__)

      def self.run(args)
        subcommand = args.shift

        case subcommand
        when 'new'
          new(args).generate
        when nil, '--help', '-h', 'help'
          print_help
        else
          puts "Unknown plugin subcommand: #{subcommand}"
          puts ''
          print_help
          exit 1
        end
      end

      def self.print_help
        puts <<~HELP
          Manage Belt plugin gems.

          Usage:
            belt plugin new <name> [options]

          Arguments:
            name                    Plugin name (e.g. messaging, pay, or belt-messaging)

          Options:
            --path DIR              Parent directory for the gem (default: current directory)
            --summary TEXT          Short gem summary for the gemspec
            --force                 Overwrite files if the directory already exists
            -h, --help              Show this help

          Examples:
            belt plugin new messaging
            belt plugin new pay --path ~/Code
            belt plugin new belt-notifications --summary "Push notifications for Belt apps"

          What you get:
            A standalone gem (belt-<name>) with:
              - Module under Belt::<Name>
              - Generator at lib/belt/generators/<name>_generator.rb
              - Configuration stub, version, RSpec, README, AGENTS.md
              - Hooked into `belt generate <name>` / `belt destroy <name>` once
                the gem is in an app's Gemfile

          Reference plugins:
            belt-messaging  — SMS via AWS End User Messaging
            belt-pay        — Stripe payments and subscriptions

          See the Belt README (Plugins / Contributing) and AGENTS.md for the full guide.
        HELP
      end

      def initialize(args)
        @raw_name = nil
        @path = Dir.pwd
        @summary = nil
        @force = false

        i = 0
        while i < args.length
          arg = args[i]
          case arg
          when '--path'
            i += 1
            @path = args[i] || Dir.pwd
          when /^--path=/
            @path = arg.split('=', 2).last
          when '--summary'
            i += 1
            @summary = args[i]
          when /^--summary=/
            @summary = arg.split('=', 2).last
          when '--force'
            @force = true
          when '--help', '-h'
            self.class.print_help
            exit 0
          else
            if arg.start_with?('-')
              puts "Unknown option: #{arg}"
              exit 1
            end
            @raw_name ||= arg
          end
          i += 1
        end
      end

      def generate
        if @raw_name.nil? || @raw_name.strip.empty?
          puts 'Usage: belt plugin new <name> [options]'
          puts "Run 'belt plugin --help' for more information."
          exit 1
        end

        normalize_names!

        if Dir.exist?(@gem_dir) && !@force
          puts "✗ Directory already exists: #{@gem_dir}"
          puts '  Use --force to overwrite, or choose a different name/path.'
          exit 1
        end

        FileUtils.mkdir_p(@gem_dir)
        write_files
        print_success
      end

      private

      def normalize_names!
        # Accept "messaging", "belt-messaging", "Belt::Messaging"
        name = @raw_name.to_s.strip
        name = name.sub(/\ABelt::/i, '')
        name = name.gsub('::', '-')
        name = name.sub(/\Abelt[-_]/i, '')
        name = name.gsub(/[^a-z0-9_-]/i, '_').downcase.tr('_', '-')
        name = name.gsub(/-+/, '-').gsub(/\A-|-\z/, '')

        if name.empty?
          puts "✗ Invalid plugin name: #{@raw_name.inspect}"
          exit 1
        end

        @plugin_name = name                          # messaging
        @gem_name = "belt-#{name}"                   # belt-messaging
        @module_name = name.split('-').map(&:capitalize).join # Messaging
        @constant_path = "Belt::#{@module_name}"     # Belt::Messaging
        @generator_class = "#{@module_name}Generator"
        @summary ||= "#{@module_name} plugin for Belt applications"
        @gem_dir = File.expand_path(File.join(@path, @gem_name))
      end

      def write_files
        files.each do |relative, content|
          full = File.join(@gem_dir, relative)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
          puts "  create  #{File.join(@gem_name, relative)}"
        end
      end

      def files
        {
          "#{@gem_name}.gemspec" => render('gemspec.erb'),
          'Gemfile' => render('Gemfile.erb'),
          'Rakefile' => render('Rakefile.erb'),
          'README.md' => render('README.md.erb'),
          'AGENTS.md' => render('AGENTS.md.erb'),
          'CHANGELOG.md' => render('CHANGELOG.md.erb'),
          'LICENSE' => render('LICENSE.erb'),
          '.gitignore' => render('gitignore.erb'),
          '.rspec' => render('rspec.erb'),
          "lib/#{@gem_name}.rb" => render('lib/entry.rb.erb'),
          "lib/belt/#{@plugin_name.tr('-', '_')}.rb" => render('lib/belt/module.rb.erb'),
          "lib/belt/#{@plugin_name.tr('-', '_')}/version.rb" => render('lib/belt/module/version.rb.erb'),
          "lib/belt/#{@plugin_name.tr('-', '_')}/configuration.rb" => render('lib/belt/module/configuration.rb.erb'),
          "lib/belt/generators/#{@plugin_name.tr('-', '_')}_generator.rb" => render('lib/belt/generators/generator.rb.erb'),
          "lib/belt/#{@plugin_name.tr('-', '_')}/templates/.gitkeep" => '',
          'spec/spec_helper.rb' => render('spec/spec_helper.rb.erb'),
          "spec/belt/#{@plugin_name.tr('-', '_')}/configuration_spec.rb" => render('spec/configuration_spec.rb.erb')
        }
      end

      def render(template_name)
        path = File.join(TEMPLATE_DIR, template_name)
        unless File.exist?(path)
          raise "Missing plugin template: #{path}"
        end

        erb = ERB.new(File.read(path), trim_mode: '-')
        # Expose locals used in templates
        gem_name = @gem_name
        plugin_name = @plugin_name
        module_name = @module_name
        constant_path = @constant_path
        generator_class = @generator_class
        summary = @summary
        underscored = @plugin_name.tr('-', '_')
        erb.result(binding)
      end

      def print_success
        puts ''
        puts "✓ Created plugin gem #{@gem_name}"
        puts ''
        puts 'Next steps:'
        puts "  1. cd #{@gem_dir}"
        puts '  2. bundle install'
        puts '  3. Implement your library under lib/belt/'
        puts "  4. Flesh out lib/belt/generators/#{@plugin_name.tr('-', '_')}_generator.rb"
        puts '     (templates go in lib/belt/<name>/templates/)'
        puts '  5. In a Belt app Gemfile:'
        puts "       gem \"#{@gem_name}\", path: \"#{@gem_dir}\""
        puts '  6. bundle install && belt generate --help'
        puts "     → should list \"#{@plugin_name}\" under Gem Generators"
        puts "  7. belt generate #{@plugin_name}"
        puts ''
        puts 'Reference implementations: belt-messaging, belt-pay'
      end
    end
  end
end
