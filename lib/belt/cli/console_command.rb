# frozen_string_literal: true

require 'optparse'

module Belt
  module CLI
    class ConsoleCommand
      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @args = args
        @options = {}
        parse_options
      end

      def run
        ENV['BUNDLE_GEMFILE'] ||= File.join(Belt.root, 'Gemfile')

        unless File.exist?(ENV['BUNDLE_GEMFILE'])
          abort "Error: No Gemfile found at #{ENV['BUNDLE_GEMFILE']}. Are you in a Belt project?"
        end

        @environment = @args.first || ENV['BELT_ENV'] || 'dev'
        ENV['ENVIRONMENT'] = @environment

        if @options[:run]
          exec_runner(@options[:run])
        else
          exec_console
        end
      end

      private

      def parse_options
        OptionParser.new do |opts|
          opts.banner = 'Usage: belt console [environment] [options]'
          opts.on('--run COMMAND', 'Execute a command and exit') { |cmd| @options[:run] = cmd }
          opts.on('-h', '--help', 'Show this help') { puts opts; exit }
        end.parse!(@args)
      end

      def exec_console
        production_guard!
        boot_app
        puts banner
        ARGV.clear
        require 'irb'
        IRB.start
      end

      def exec_runner(command)
        boot_app
        result = eval(command) # rubocop:disable Security/Eval
        puts format_result(result)
      rescue => e
        abort "Error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      end

      def boot_app
        require 'bundler/setup'

        environment_file = File.join(Belt.root, 'lambda', 'config', 'environment.rb')
        if File.exist?(environment_file)
          load environment_file
        else
          require 'belt'
          load_dir('lib')
          load_dir('models')
        end

        define_reload!
      end

      def load_dir(subdir)
        dir = File.join(Belt.root, 'lambda', subdir)
        Dir.glob(File.join(dir, '**', '*.rb')).sort.each { |f| require f } if Dir.exist?(dir)
      end

      def define_reload!
        root = Belt.root
        Kernel.define_method(:reload!) do
          %w[lib models].each do |subdir|
            dir = File.join(root, 'lambda', subdir)
            Dir.glob(File.join(dir, '**', '*.rb')).sort.each { |f| load f } if Dir.exist?(dir)
          end
          puts '♻️  Reloaded'
        end
      end

      def production_guard!
        return unless @environment == 'prod'

        $stdout.write "\n⚠️  WARNING: You are entering the PRODUCTION console!\nType 'yes' to continue: "
        response = $stdin.gets&.chomp
        abort "\n❌ Cancelled." unless response&.downcase == 'yes'
        puts "\n✅ Entering production console...\n"
      end

      def banner
        <<~BANNER

          Belt Console (#{@environment})
          Type 'reload!' to reload code.

        BANNER
      end

      def format_result(result)
        require 'json'
        if result.respond_to?(:to_h)
          JSON.pretty_generate(result.to_h)
        elsif result.respond_to?(:map) && result.respond_to?(:first) && result.first.respond_to?(:to_h)
          JSON.pretty_generate(result.map(&:to_h))
        elsif result.nil?
          'nil'
        else
          result.inspect
        end
      end
    end
  end
end
