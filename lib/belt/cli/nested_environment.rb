# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'environment_config'

module Belt
  module CLI
    # A nested environment (e.g. fizzy123 under dev). Nested envs share the
    # parent's Cognito pool and get a one-time DynamoDB copy on first deploy.
    class NestedEnvironment
      PARENT_TFVARS = /^\s*parent_environment\s*=\s*"([^"]+)"/

      attr_reader :env, :parent, :infra_dir

      # Populated by terraform_outputs when a read fails so callers (e.g.
      # CognitoSharer) can explain *why* the parent pool couldn't be read
      # instead of emitting a vague warning.
      attr_reader :last_output_error

      def self.parent_of(env, infra_dir:)
        path = File.join(infra_dir, env, 'terraform.tfvars')
        return nil unless File.file?(path)

        match = File.read(path).match(PARENT_TFVARS)
        parent = match && match[1]
        parent.nil? || parent.empty? ? nil : parent
      end

      def self.for(env, infra_dir:)
        parent = parent_of(env, infra_dir: infra_dir)
        return nil unless parent
        return nil unless Dir.exist?(File.join(infra_dir, parent))

        new(env: env, parent: parent, infra_dir: infra_dir)
      end

      def initialize(env:, parent:, infra_dir:)
        @env = env
        @parent = parent
        @infra_dir = infra_dir
      end

      def env_dir
        File.join(@infra_dir, @env)
      end

      def parent_dir
        File.join(@infra_dir, @parent)
      end

      def child_outputs
        @child_outputs ||= terraform_outputs(env_dir)
      end

      def parent_outputs
        # Read the parent under the parent's own AWS profile — a nested env may
        # deploy with a different profile than its parent, and `terraform
        # output` hits the S3 backend, so it needs the parent's credentials.
        @parent_outputs ||= with_parent_profile { terraform_outputs(parent_dir) }
      end

      def parent_cognito_pool_id
        pick_output(parent_outputs, %w[cognito_user_pool_id user_pool_id cognito_pool_id])
      end

      def parent_cognito_client_id
        pick_output(parent_outputs, %w[cognito_user_pool_client_id cognito_client_id user_pool_client_id])
      end

      def parent_cognito_region
        pick_output(parent_outputs, %w[cognito_region aws_region]) || ENV['AWS_REGION'] || 'us-east-1'
      end

      def child_cognito_pool_id
        pick_output(child_outputs, %w[cognito_user_pool_id user_pool_id cognito_pool_id])
      end

      def child_cognito_client_id
        pick_output(child_outputs, %w[cognito_user_pool_client_id cognito_client_id user_pool_client_id])
      end

      def parent_issuer
        pool_id = parent_cognito_pool_id
        return nil unless pool_id

        "https://cognito-idp.#{parent_cognito_region}.amazonaws.com/#{pool_id}"
      end

      private

      def pick_output(outputs, keys)
        keys.each do |key|
          val = outputs[key]
          return val if val.is_a?(String) && !val.empty?
        end
        nil
      end

      def terraform_outputs(dir)
        return {} unless Dir.exist?(dir)

        output, err, status = run_output(dir)

        # A fresh worktree (or a parent that was only ever deployed elsewhere)
        # may not have an initialized backend yet. `terraform output` then
        # fails with "Backend initialization required". Init once and retry
        # before giving up so the parent's outputs are actually readable.
        if !status.success? && backend_not_initialized?(err)
          init_backend(dir)
          output, err, status = run_output(dir)
        end

        unless status.success?
          @last_output_error = err.to_s.strip
          return {}
        end

        parse_outputs(output)
      rescue JSON::ParserError, Errno::ENOENT => e
        @last_output_error = e.message
        {}
      end

      def run_output(dir)
        Open3.capture3('terraform', 'output', '-json', chdir: dir)
      end

      def backend_not_initialized?(err)
        err.to_s.match?(/backend initialization|terraform init|Backend reinitialization/i)
      end

      def init_backend(dir)
        Open3.capture3('terraform', 'init', '-input=false', chdir: dir)
      end

      def parse_outputs(output)
        parsed = JSON.parse(output)
        parsed.each_with_object({}) do |(key, spec), hash|
          hash[key] = spec.is_a?(Hash) && spec.key?('value') ? spec['value'] : spec
        end
      end

      # Apply the parent env's AWS profile (from its belt.rb) for the duration
      # of the block, then restore whatever profile the child deploy set.
      def with_parent_profile
        parent_profile = EnvironmentConfig.load(@parent, infra_dir: @infra_dir).aws_profile
        return yield if parent_profile.nil? || parent_profile.empty?

        previous = ENV.fetch('AWS_PROFILE', nil)
        ENV['AWS_PROFILE'] = parent_profile
        begin
          yield
        ensure
          if previous.nil?
            ENV.delete('AWS_PROFILE')
          else
            ENV['AWS_PROFILE'] = previous
          end
        end
      end
    end
  end
end
