# frozen_string_literal: true

require_relative 'env_resolver'

module Belt
  module CLI
    class TerraformCommand
      ACTIONS = %w[init plan apply destroy output].freeze

      def self.run(action, args)
        env = EnvResolver.resolve(args)

        if env.nil?
          puts "Usage: belt #{action} <environment> [terraform flags...]"
          puts "\nYou can also set BELT_ENV to skip the environment argument."
          puts "\nExamples:"
          puts "  belt #{action} wups"
          puts "  belt #{action} dev01"
          puts "  BELT_ENV=wups belt #{action}"
          puts '  belt plan staging -target=module.lambda'
          puts "\nAvailable environments:"
          list_environments.each { |e| puts "  #{e}" }
          exit 1
        end

        new(action, env, args).run
      end

      def self.list_environments
        infra_dir = find_infrastructure_dir
        return [] unless infra_dir

        Dir.children(infra_dir)
           .select { |d| File.directory?(File.join(infra_dir, d)) }
           .reject { |d| d.start_with?('.') || d == 'modules' }
           .sort
      end

      def self.find_infrastructure_dir
        %w[infrastructure infra].each do |dir|
          return dir if Dir.exist?(dir)
        end
        nil
      end

      def initialize(action, env, extra_args)
        @action = action
        @env = env
        @extra_args = extra_args
        @infra_dir = self.class.find_infrastructure_dir
      end

      def run
        validate!
        env_dir = File.join(@infra_dir, @env)
        args = ['terraform', @action, *@extra_args]
        puts "belt → #{args.join(' ')}  (in #{env_dir}/)"
        Dir.chdir(env_dir) { exec(*args) }
      end

      private

      def validate!
        unless @infra_dir
          abort "Error: No infrastructure/ directory found. Run `belt generate environment #{@env}` first."
        end

        env_dir = File.join(@infra_dir, @env)
        return if Dir.exist?(env_dir)

        abort "Error: Environment '#{@env}' not found at #{env_dir}/.\n\n" \
              "Available environments:\n#{self.class.list_environments.map { |e| "  #{e}" }.join("\n")}\n\n" \
              "Create it with: belt generate environment #{@env}"
      end
    end
  end
end
