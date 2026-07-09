# frozen_string_literal: true

module Belt
  module CLI
    module AppDetection
      def detect_app_name
        routes_file = 'infrastructure/routes.tf.rb'
        if File.exist?(routes_file)
          match = File.read(routes_file).match(/namespace :(\w+)/)
          return match[1] if match
        end
        File.basename(Dir.pwd)
      end

      # S3 bucket names follow DNS rules — underscores are not allowed.
      # App names often use underscores (Ruby namespaces); convert for S3.
      def s3_safe_name(name)
        name.to_s.downcase.tr('_', '-')
      end
    end
  end
end
