# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'

module Belt
  module CLI
    # Records which data migrations have run against an environment, as one
    # SSM parameter per version:
    #
    #   /belt/<app>/<env>/schema_migrations/<version>
    #
    # SSM rather than a DynamoDB table so the record isn't part of the
    # `<app>-<env>-*` tables that `belt db:copy` and the nested-env copy move
    # between environments — each stack keeps its own history.
    class MigrationStore
      class Error < StandardError; end

      def initialize(app_name:, env:)
        @app_name = app_name
        @env = env
      end

      def path
        "/belt/#{@app_name}/#{@env}/schema_migrations"
      end

      # Versions already applied to this environment, as strings.
      def applied_versions
        data = aws_json('ssm', 'get-parameters-by-path', '--path', path, '--output', 'json')
        Array(data['Parameters']).map { |param| File.basename(param['Name']) }
      end

      def record!(version, name)
        value = JSON.generate('name' => name, 'applied_at' => Time.now.utc.iso8601)
        aws_json('ssm', 'put-parameter', '--name', "#{path}/#{version}", '--type', 'String',
                 '--value', value, '--overwrite', '--output', 'json')
      end

      private

      def aws_json(*args)
        command = "aws #{args.first(2).join(' ')}"
        output, error, status = Open3.capture3('aws', *args)
        raise Error, "#{command} failed: #{error.strip}" unless status.success?

        output.strip.empty? ? {} : JSON.parse(output)
      rescue JSON::ParserError => e
        raise Error, "#{command} returned invalid JSON: #{e.message}"
      end
    end
  end
end
