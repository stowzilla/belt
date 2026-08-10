# frozen_string_literal: true

module Belt
  module CLI
    module AppDetection
      # Detects the primary gateway from the route definitions.
      # Used by generators to determine controller directory and route file naming.
      def detect_namespace
        routes_file = find_routes_file_path
        if routes_file && File.exist?(routes_file)
          content = File.read(routes_file)
          # Prefer `gateway :name` but fall back to legacy `namespace :name` at top-level
          match = content.match(/^\s*gateway :(\w+)/) || content.match(/^\s*namespace :(\w+)/)
          return match[1] if match
        end
        File.basename(Dir.pwd)
      end

      # Detects the application name.
      # Prefers terraform.tfvars app_name, then falls back to directory name.
      def detect_app_name
        # Check any environment tfvars for the app_name
        Dir.glob('infrastructure/*/terraform.tfvars').each do |f|
          content = File.read(f)
          match = content.match(/app_name\s*=\s*"([^"]+)"/)
          return match[1] if match
        end

        # Fall back to directory name
        File.basename(Dir.pwd)
      end

      # Detects existing environments by scanning infrastructure/ directories.
      # Each subdirectory with a main.tf is considered an environment.
      def detect_environments
        Dir.glob('infrastructure/*/main.tf').map { |f| File.basename(File.dirname(f)) }.sort
      end

      # S3 bucket names follow DNS rules — underscores are not allowed.
      # App names often use underscores (Ruby namespaces); convert for S3.
      def s3_safe_name(name)
        name.to_s.downcase.tr('_', '-')
      end

      # Finds routes file checking config/routes.rb first, then legacy paths.
      def find_routes_file_path
        candidates = [
          'config/routes.rb',
          'config/routes.tf.rb',
          'infrastructure/routes.tf.rb'
        ]
        candidates.find { |f| File.exist?(f) }
      end

      # Finds contracts file checking config/contracts.rb first, then legacy paths.
      def find_contracts_file_path
        candidates = [
          'config/contracts.rb',
          'config/contracts.tf.rb',
          'config/schema.tf.rb',
          'infrastructure/schema.tf.rb'
        ]
        candidates.find { |f| File.exist?(f) }
      end

      # Legacy alias for backward compatibility
      def find_schema_file_path
        find_contracts_file_path
      end
    end
  end
end
