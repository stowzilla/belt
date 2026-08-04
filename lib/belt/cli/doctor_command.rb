# frozen_string_literal: true

require 'json'
require 'open3'
require_relative '../../belt/inflector'

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
        preflight = args.include?('--preflight')

        if args.include?('--help') || args.include?('-h')
          puts usage
          exit 0
        end

        new(verbose: verbose, preflight: preflight).run
      end

      def self.usage
        <<~USAGE
          Usage: belt doctor [options]

          Check system dependencies and AWS configuration for Belt.

          Options:
            -v, --verbose      Show detailed output for each check
            --preflight        Run only deploy-critical checks (indexes, credentials)
            -h, --help         Show this help
        USAGE
      end

      def initialize(verbose: false, preflight: false)
        @verbose = verbose
        @preflight = preflight
        @issues = []
        @warnings = []
      end

      def run # rubocop:disable Naming/PredicateMethod
        if @preflight
          run_preflight
        else
          run_full
        end

        @issues.empty?
      end

      # Returns true if all preflight checks pass, false otherwise.
      def run_preflight
        check_aws_identity_quiet
        check_table_indexes
        check_cognito_auth
        return if @issues.empty?

        puts "\nPreflight checks failed:\n"
        @issues.each { |i| puts "  ✗ #{i}" }
        puts ''
      end

      def run_full
        puts "Belt Doctor\n"
        puts "Checking your system for Belt prerequisites...\n\n"

        check_tools
        check_aws_credentials
        check_aws_identity
        check_table_indexes
        check_cognito_auth

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
          handle_aws_identity_error(output.strip)
        end
      end

      def check_aws_identity_quiet
        _, status = Open3.capture2e('aws', 'sts', 'get-caller-identity')
        return if status.success?

        @issues << 'AWS credentials invalid or expired — run `aws sso login`'
      end

      def handle_aws_identity_error(error)
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

      def check_table_indexes
        return unless Belt.root?

        models_dir = File.join(Belt.root, 'lambda/models')
        dynamodb_tf = File.join(Belt.root, 'infrastructure/modules/app/dynamodb.tf')

        return unless Dir.exist?(models_dir)

        puts ''
        puts '── Tables & Indexes ──'

        unless File.exist?(dynamodb_tf)
          print_warn('dynamodb.tf', 'not found — run `belt setup tables` to generate')
          @warnings << 'dynamodb.tf not generated — run `belt setup tables`'
          return
        end

        tf_content = File.read(dynamodb_tf)
        model_files = Dir.glob(File.join(models_dir, '*.rb'))
                         .reject { |f| File.basename(f) == 'application_record.rb' }

        model_files.each do |file|
          check_model_indexes(file, tf_content)
        end
      end

      def check_model_indexes(file, tf_content)
        content = File.read(file)
        class_match = content.match(/^class\s+(\w+)\s*<\s*ApplicationRecord/)
        return unless class_match

        model_name = Belt::Inflector.underscore(class_match[1])
        table_name = Belt::Inflector.pluralize(model_name)

        # Check if table exists in dynamodb.tf
        unless tf_content.include?("resource \"aws_dynamodb_table\" \"#{table_name}\"")
          print_fail(table_name, 'table not in dynamodb.tf')
          @issues << "Table '#{table_name}' missing from dynamodb.tf — run `belt setup tables`"
          return
        end

        # Extract expected indexes from belongs_to
        expected_indexes = extract_expected_indexes(content)
        return if expected_indexes.empty?

        # Check each expected index exists in the TF file
        # Scope check to this table's resource block
        table_block = tf_content[/resource "aws_dynamodb_table" "#{table_name}" \{.*?^\}/m]
        return unless table_block

        missing = []
        expected_indexes.each do |idx|
          if table_block.include?("name            = \"#{idx[:name]}\"")
            print_ok(table_name, idx[:name]) if @verbose
          else
            missing << idx
          end
        end

        if missing.empty?
          print_ok(table_name, "#{expected_indexes.size} index#{'es' if expected_indexes.size > 1} configured")
        else
          missing.each do |idx|
            print_fail(table_name, "missing #{idx[:name]} (required by belongs_to :#{idx[:association]})")
            @issues << "Table '#{table_name}' missing index '#{idx[:name]}' " \
                       '— run `belt setup tables` then `belt deploy`'
          end
        end
      end

      def extract_expected_indexes(content)
        indexes = []
        content.lines.reject { |line| line.strip.start_with?('#') }.join
               .scan(/belongs_to\s+:(\w+)/) do |match|
          association_name = match[0]
          indexes << {
            name: "#{Belt::Inflector.classify(association_name)}Index",
            association: association_name
          }
        end
        indexes
      end

      def check_cognito_auth
        return unless Belt.root?

        routes_file = Belt.routes_file
        return unless routes_file

        content = File.read(routes_file)

        # Check if any routes use auth: :cognito
        uses_cognito = content.include?('auth: :cognito')
        return unless uses_cognito

        # Check if cognito.tf exists
        cognito_tf = File.join(Belt.root, 'infrastructure/modules/app/cognito.tf')
        return if File.exist?(cognito_tf)

        puts ''
        puts '── Authentication ──'
        print_warn('Cognito', 'routes use auth: :cognito but no cognito.tf found')
        puts '         Run: belt generate auth'
        @warnings << 'Routes use auth: :cognito but no Cognito pool is configured — run `belt generate auth`'
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
