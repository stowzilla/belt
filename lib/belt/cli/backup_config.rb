# frozen_string_literal: true

module Belt
  module CLI
    class BackupConfig
      attr_reader :dynamodb_tables, :cognito_exports, :s3_buckets, :retention

      # Load backup config from infrastructure/<env>/belt.rb
      # Returns nil if no config file exists or backups aren't configured
      # NOTE: Prefer EnvironmentConfig.load which loads the full config including backups.
      #       This method is kept for backward compatibility.
      def self.load(env, infra_dir: nil)
        env_config = EnvironmentConfig.load(env, infra_dir: infra_dir)
        env_config.backups? ? env_config.backup_config : nil
      end

      def initialize
        @dynamodb_tables = nil # nil = not configured, :all = all tables, Array = specific tables
        @cognito_exports = []  # e.g. [:users, :pool_config]
        @s3_buckets = []       # e.g. [:legal_documents]
        @retention = { snapshots: 90, cognito: 10, s3: 10 }
      end

      def dynamodb?
        !@dynamodb_tables.nil?
      end

      def cognito?
        @cognito_exports.any?
      end

      def any?
        dynamodb? || cognito? || @s3_buckets.any?
      end
    end
  end
end
