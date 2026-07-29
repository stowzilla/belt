# frozen_string_literal: true

require 'json'
require 'open3'

module Belt
  module CLI
    class DoctorCommand
      REQUIRED_TOOLS = [
        { name: 'aws', check: %w[aws --version],
          install_url: 'https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html' },
        { name: 'terraform', check: %w[terraform --version],
          install_url: 'https://developer.hashicorp.com/terraform/install' },
        { name: 'ruby', check: %w[ruby --version], min_version: '3.3' },
        { name: 'bundler', check: %w[bundle --version], install_hint: 'gem install bundler' }
      ].freeze

      def self.run(args)
        verbose = args.include?('--verbose') || args.include?('-v')

        if args.include?('--help') || args.include?('-h')
          puts usage
          exit 0
        end

        new(verbose: verbose).run
      end

      def self.usage
        <<~USAGE
          Usage: belt doctor [options]

          Check system dependencies and AWS configuration for Belt.

          Options:
            -v, --verbose    Show detailed output for each check
            -h, --help       Show this help
        USAGE
      end

      def initialize(verbose: false)
        @verbose = verbose
        @issues = []
        @warnings = []
      end

      def run
        puts "Belt Doctor\n"
        puts "Checking your system for Belt prerequisites...\n\n"

        check_tools
        check_aws_credentials
        check_aws_identity

        puts ''
        print_summary
      end

      private

      def check_tools
        puts '── Tools ──'
        REQUIRED_TOOLS.each do |tool|
          check_tool(tool)
        end
        puts ''
      end

      def check_tool(tool)
        output, status = Open3.capture2e(*tool[:check])

        if status.success?
          version = extract_version(output)
          if tool[:min_version] && version && Gem::Version.new(version) < Gem::Version.new(tool[:min_version])
            print_warn(tool[:name], "found #{version}, need >= #{tool[:min_version]}")
            @warnings << "#{tool[:name]} version #{version} is below minimum #{tool[:min_version]}"
          else
            print_ok(tool[:name], version ? version.to_s : output.strip.lines.first&.strip)
          end
        else
          print_fail(tool[:name], 'not found')
          hint = tool[:install_hint] || tool[:install_url]
          puts "         Install: #{hint}" if hint
          @issues << "#{tool[:name]} is not installed"
        end
      end

      def check_aws_credentials
        puts '── AWS Configuration ──'

        # Check for credential sources
        has_profile = ENV.fetch('AWS_PROFILE', nil) && !ENV['AWS_PROFILE'].empty?
        has_env_keys = ENV.fetch('AWS_ACCESS_KEY_ID', nil) && !ENV['AWS_ACCESS_KEY_ID'].empty?
        has_config_file = File.exist?(File.expand_path('~/.aws/config'))
        has_credentials_file = File.exist?(File.expand_path('~/.aws/credentials'))

        if has_profile
          print_ok('AWS_PROFILE', ENV.fetch('AWS_PROFILE', nil))
        elsif has_env_keys
          print_ok('AWS_ACCESS_KEY_ID', 'set (environment variable)')
        elsif has_credentials_file
          print_ok('~/.aws/credentials', 'exists')
        elsif has_config_file
          print_ok('~/.aws/config', 'exists')
        else
          print_fail('AWS credentials', 'no credential source found')
          puts '         Set AWS_PROFILE, or configure credentials via:'
          puts '           aws configure sso    # SSO (recommended)'
          puts '           aws configure        # access key + secret'
          @issues << 'No AWS credentials configured'
          return
        end

        # Check config file for profiles
        return unless has_config_file && @verbose

        profiles = parse_aws_config_profiles
        puts "         Profiles: #{profiles.join(', ')}" if profiles.any?
      end

      def check_aws_identity
        output, status = Open3.capture2e('aws', 'sts', 'get-caller-identity')

        if status.success?
          data = begin
            JSON.parse(output)
          rescue JSON::ParserError
            {}
          end
          account = data['Account'] || '?'
          arn = data['Arn'] || '?'
          print_ok('Authentication', "account #{account}")
          puts "         ARN: #{arn}" if @verbose
        else
          error = output.strip
          if error.include?('ExpiredToken') || error.include?('expired')
            print_fail('Authentication', 'credentials expired')
            puts '         Run: aws sso login'
            @issues << 'AWS credentials are expired — run `aws sso login`'
          elsif error.include?('InvalidClientTokenId') || error.include?('SignatureDoesNotMatch')
            print_fail('Authentication', 'invalid credentials')
            puts '         Your access key or secret is incorrect.'
            puts '         Run: aws configure'
            @issues << 'AWS credentials are invalid'
          elsif error.include?('Could not connect') || error.include?('Unable to locate credentials')
            print_fail('Authentication', 'unable to authenticate')
            puts '         Run: aws configure sso    # or set AWS_PROFILE'
            @issues << 'Unable to authenticate with AWS'
          else
            print_fail('Authentication', 'failed')
            puts "         #{error.lines.first&.strip}" if error.length.positive?
            @issues << 'AWS authentication failed'
          end
        end
      end

      def print_summary
        if @issues.empty? && @warnings.empty?
          puts '✓ All checks passed — you\'re ready to belt!'
        elsif @issues.empty?
          puts "⚠ #{@warnings.size} warning#{'s' if @warnings.size > 1}:"
          @warnings.each { |w| puts "  • #{w}" }
        else
          puts "✗ #{@issues.size} issue#{'s' if @issues.size > 1} found:"
          @issues.each { |i| puts "  • #{i}" }
          @warnings.each { |w| puts "  • ⚠ #{w}" } if @warnings.any?
          puts "\nFix the issues above, then run `belt doctor` again."
          exit 1
        end
      end

      def print_ok(label, detail = nil)
        msg = "  ✓ #{label}"
        msg += " — #{detail}" if detail
        puts msg
      end

      def print_fail(label, detail = nil)
        msg = "  ✗ #{label}"
        msg += " — #{detail}" if detail
        puts msg
      end

      def print_warn(label, detail = nil)
        msg = "  ⚠ #{label}"
        msg += " — #{detail}" if detail
        puts msg
      end

      def extract_version(output)
        # Match common version patterns:
        #   "aws-cli/2.15.0" "Terraform v1.7.0" "Bundler version 2.5.0" "ruby 3.3.0"
        match = output.match(%r{(?:version\s+|v|/|^ruby\s+)(\d+\.\d+(?:\.\d+)?)}i)
        match ? match[1] : nil
      end

      def parse_aws_config_profiles
        config_path = File.expand_path('~/.aws/config')
        return [] unless File.exist?(config_path)

        File.readlines(config_path)
            .filter_map { |line| line.match(/\[profile\s+(.+)\]/)&.captures&.first }
      rescue StandardError
        []
      end
    end
  end
end
