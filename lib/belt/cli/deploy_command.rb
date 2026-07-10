# frozen_string_literal: true

require_relative 'env_resolver'
require_relative 'terraform_command'

module Belt
  module CLI
    class DeployCommand
      def self.run(args)
        # Handle `belt deploy frontend <env>` as before
        if args.first == 'frontend'
          args.shift
          Belt::CLI::FrontendDeployCommand.run(args)
          return
        end

        auto_approve = false
        filtered_args = []

        args.each do |arg|
          case arg
          when '--auto', '--yes', '-y'
            auto_approve = true
          when '-h', '--help'
            puts help_text
            exit 0
          else
            filtered_args << arg
          end
        end

        env = EnvResolver.resolve(filtered_args)

        # Default to the first available environment when none specified
        if env.nil?
          available = TerraformCommand.list_environments
          if available.any?
            env = available.first
          else
            puts 'Usage: belt deploy [environment] [options]'
            puts "\nDefaults to BELT_ENV or the first available environment."
            puts "\nOptions:"
            puts '  --auto, --yes, -y    Skip confirmation prompt (auto-approve)'
            puts '  -h, --help           Show this help'
            puts "\nExamples:"
            puts '  belt deploy                # Deploy dev (or BELT_ENV)'
            puts '  belt deploy prod           # Deploy to prod'
            puts '  belt deploy dev --auto     # Deploy without confirmation'
            puts '  belt deploy frontend dev   # Deploy frontend only'
            puts "\nNo environments found. Run `belt generate environment dev` first."
            exit 1
          end
        end

        new(env, auto_approve: auto_approve, extra_args: filtered_args).run
      end

      def self.help_text
        <<~HELP
          Deploy your Belt application to AWS.

          Usage: belt deploy [environment] [options]
                 belt deploy frontend <environment>

          This runs the full deployment lifecycle:
            1. terraform init    (initialize providers/modules)
            2. terraform plan    (preview changes)
            3. Prompt for confirmation (unless --auto)
            4. terraform apply   (deploy changes)

          Options:
            --auto, --yes, -y    Skip confirmation prompt (auto-approve)
            -h, --help           Show this help

          Environment:
            Defaults to BELT_ENV if set, otherwise requires an argument.

          Examples:
            belt deploy                # Deploy dev (or BELT_ENV)
            belt deploy prod           # Deploy to prod
            belt deploy dev --auto     # Deploy without confirmation (CI mode)
            belt deploy frontend dev   # Deploy frontend assets only
        HELP
      end

      def initialize(env, auto_approve: false, extra_args: [])
        @env = env
        @auto_approve = auto_approve
        @extra_args = extra_args
        @infra_dir = TerraformCommand.find_infrastructure_dir
      end

      def run
        validate!
        env_dir = File.join(@infra_dir, @env)

        puts "belt → deploying #{@env} (in #{env_dir}/)\n\n"

        Dir.chdir(env_dir) do
          run_init
          run_plan
          return unless confirm_apply
          run_apply
        end

        puts "\n✅ Deployed #{@env} successfully!"
        print_outputs(env_dir)
        puts "\n   Run `belt server` to view your app locally (auto-connects to the deployed API)."
      end

      private

      def validate!
        unless @infra_dir
          abort "Error: No infrastructure/ directory found.\n" \
                "Run `belt generate environment #{@env}` first."
        end

        env_dir = File.join(@infra_dir, @env)
        return if Dir.exist?(env_dir)

        abort "Error: Environment '#{@env}' not found at #{env_dir}/.\n\n" \
              "Available environments:\n#{TerraformCommand.list_environments.map { |e| "  #{e}" }.join("\n")}\n\n" \
              "Create it with: belt generate environment #{@env}"
      end

      def run_init
        puts '━━━ terraform init ━━━'
        success = system('terraform', 'init')
        abort "\n✗ terraform init failed" unless success
        puts ''
      end

      def run_plan
        puts '━━━ terraform plan ━━━'
        success = system('terraform', 'plan', '-out=tfplan', *@extra_args)
        abort "\n✗ terraform plan failed" unless success
        puts ''
      end

      def confirm_apply
        return true if @auto_approve

        if @env == 'prod' || @env == 'production'
          print "⚠️  You are about to deploy to \e[1;31m#{@env}\e[0m. Continue? [y/N] "
        else
          print "Apply these changes to #{@env}? [y/N] "
        end

        response = $stdin.gets
        return true if response&.strip&.downcase&.start_with?('y')

        puts 'Cancelled.'
        cleanup_plan
        false
      end

      def run_apply
        puts '━━━ terraform apply ━━━'
        success = system('terraform', 'apply', 'tfplan')
        cleanup_plan
        abort "\n✗ terraform apply failed" unless success
      end

      def cleanup_plan
        File.delete('tfplan') if File.exist?('tfplan')
      end

      def print_outputs(env_dir)
        Dir.chdir(env_dir) do
          output = `terraform output 2>/dev/null`.strip
          return if output.empty?

          puts "\nOutputs:"
          output.each_line do |line|
            puts "  #{line}"
          end
        end
      end
    end
  end
end
