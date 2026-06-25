# frozen_string_literal: true

module Belt
  module CLI
    class ConsoleCommand
      def self.run(_args)
        unless File.exist?(gemfile_path)
          abort "Error: No Gemfile found at #{gemfile_path}. Are you in a Belt project?"
        end

        ENV['BUNDLE_GEMFILE'] ||= gemfile_path

        boot_file = File.join(Belt.root, 'lambda', 'bin', 'console.rb')
        if File.exist?(boot_file)
          exec('ruby', boot_file)
        else
          exec_irb
        end
      end

      def self.gemfile_path
        File.join(Belt.root, 'Gemfile')
      end

      def self.exec_irb
        require 'bundler/setup'
        load_app
        require 'irb'
        IRB.start
      end

      def self.load_app
        require 'belt'

        models_dir = File.join(Belt.root, 'lambda', 'models')
        if Dir.exist?(models_dir)
          Dir.glob(File.join(models_dir, '**', '*.rb')).sort.each { |f| require f }
        end
      end
    end
  end
end
