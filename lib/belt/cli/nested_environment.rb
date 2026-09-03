# frozen_string_literal: true

require 'json'
require 'open3'

module Belt
  module CLI
    # A nested environment (e.g. fizzy123 under dev). Nested envs share the
    # parent's Cognito pool and get a one-time DynamoDB copy on first deploy.
    class NestedEnvironment
      PARENT_TFVARS = /^\s*parent_environment\s*=\s*"([^"]+)"/

      attr_reader :env, :parent, :infra_dir

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
        @parent_outputs ||= terraform_outputs(parent_dir)
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

        output, status = Open3.capture2('terraform', 'output', '-json', chdir: dir, err: File::NULL)
        return {} unless status.success?

        parsed = JSON.parse(output)
        parsed.each_with_object({}) do |(key, spec), hash|
          hash[key] = spec.is_a?(Hash) && spec.key?('value') ? spec['value'] : spec
        end
      rescue JSON::ParserError, Errno::ENOENT
        {}
      end
    end
  end
end
