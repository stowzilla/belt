# frozen_string_literal: true

require 'json'
require 'open3'
require 'tempfile'
require_relative 'nested_environment'

module Belt
  module CLI
    # Points a nested environment's Lambdas at the parent Cognito pool.
    #
    # Nested envs still *create* their own pool when the app's terraform isn't
    # the Belt-generated auth template. After apply we rewrite COGNITO_* env
    # vars so login and JWT checks use the parent. Destroy only tears down the
    # nested pool — the parent pool is never in the child's terraform state.
    class CognitoSharer
      POOL_KEY = /cognito.*pool.?id/i
      CLIENT_KEY = /cognito.*client/i
      ISSUER_KEY = /cognito.*issuer/i

      def initialize(nested_env)
        @nested = nested_env
      end

      # rubocop:disable Naming/PredicateMethod
      def run
        # rubocop:enable Naming/PredicateMethod
        pool_id = @nested.parent_cognito_pool_id
        unless pool_id
          puts '  ⚠  Could not read parent Cognito pool ID — nested env will use its own pool'
          reason = @nested.last_output_error
          detail = if reason && !reason.empty?
                     "terraform output for '#{@nested.parent}' failed: #{reason.lines.first&.strip}"
                   else
                     "no cognito_user_pool_id output found in '#{@nested.parent}'"
                   end
          puts "     (#{detail})"
          return false
        end

        names = lambda_function_names
        if names.empty?
          puts '  ℹ  No Lambda functions found to rewire for Cognito'
          return true
        end

        puts "  🔑 Sharing parent '#{@nested.parent}' Cognito pool (#{pool_id})"

        names.each { |name| rewire_function(name, pool_id) }
        true
      end

      private

      def lambda_function_names
        funcs = @nested.child_outputs['lambda_functions']
        names = case funcs
                when Hash then funcs.values
                when Array then funcs
                else []
                end
        names.map { |value| value.to_s.split(':').last }.reject(&:empty?).uniq
      end

      def rewire_function(function_name, pool_id)
        wait_until_ready(function_name)

        config = aws_json('lambda', 'get-function-configuration',
                          '--function-name', function_name, '--output', 'json')
        unless config
          puts "    ⚠  #{function_name}: could not read configuration"
          return
        end

        variables = config.dig('Environment', 'Variables')
        unless variables.is_a?(Hash) && variables.any?
          puts "    skip  #{function_name} (no environment variables)"
          return
        end

        updated = rewrite_variables(variables, pool_id)
        if updated == variables
          puts "    skip  #{function_name} (already on parent pool)"
          return
        end

        if update_environment(function_name, updated)
          puts "    rewire  #{function_name}"
        else
          puts "    ⚠  #{function_name}: failed to update Cognito env vars"
        end
      end

      def rewrite_variables(variables, pool_id)
        client_id = @nested.parent_cognito_client_id
        issuer = @nested.parent_issuer
        child_pool = @nested.child_cognito_pool_id
        child_client = @nested.child_cognito_client_id

        variables.each_with_object({}) do |(key, value), hash|
          hash[key] = new_value_for(key, value, pool_id: pool_id, client_id: client_id,
                                                issuer: issuer, child_pool: child_pool,
                                                child_client: child_client)
        end
      end

      def new_value_for(key, value, pool_id:, client_id:, issuer:, child_pool:, child_client:)
        return pool_id if key.match?(POOL_KEY) || (child_pool && value == child_pool)
        return client_id if client_id && (key.match?(CLIENT_KEY) || value == child_client)
        return issuer if issuer && key.match?(ISSUER_KEY)

        value
      end

      def update_environment(function_name, variables)
        payload = { 'FunctionName' => function_name, 'Environment' => { 'Variables' => variables } }
        Tempfile.create(['belt-cognito', '.json']) do |file|
          file.write(JSON.generate(payload))
          file.flush
          _output, status = Open3.capture2(
            'aws', 'lambda', 'update-function-configuration',
            '--cli-input-json', "file://#{file.path}",
            '--output', 'json'
          )
          status.success?
        end
      end

      def wait_until_ready(function_name)
        30.times do
          output, status = Open3.capture2(
            'aws', 'lambda', 'get-function-configuration',
            '--function-name', function_name,
            '--query', 'LastUpdateStatus',
            '--output', 'text'
          )
          return unless status.success?

          case output.strip
          when 'Successful' then return
          when 'Failed' then return
          else
            sleep 1
          end
        end
      end

      def aws_json(*)
        output, status = Open3.capture2('aws', *)
        return nil unless status.success?

        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
