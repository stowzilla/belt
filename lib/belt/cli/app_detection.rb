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
      # Priority: terraform.tfvars app_name > variables.tf default > directory name.
      def detect_app_name
        # Check any environment tfvars for the app_name
        Dir.glob('infrastructure/*/terraform.tfvars').each do |f|
          content = File.read(f)
          match = content.match(/app_name\s*=\s*"([^"]+)"/)
          return match[1] if match
        end

        # Check variables.tf for a default app_name value
        name = detect_app_name_from_variables_tf
        return name if name

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

      private

      # Parses `variable "app_name" { default = "..." }` from any environment's variables.tf.
      # This handles the common pattern where app_name is a Terraform variable with a default
      # rather than being set directly in terraform.tfvars.
      def detect_app_name_from_variables_tf
        Dir.glob('infrastructure/*/variables.tf').each do |f|
          content = File.read(f)
          # Match the app_name variable block and extract its default value
          next unless content.match?(/variable\s+"app_name"/)

          # Extract default from within the variable block
          block_match = content.match(/variable\s+"app_name"\s*\{([^}]*)\}/m)
          next unless block_match

          default_match = block_match[1].match(/default\s*=\s*"([^"]+)"/)
          return default_match[1] if default_match
        end
        nil
      end
    end
  end
end
