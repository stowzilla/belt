# frozen_string_literal: true

module Belt
  # Runtime configuration for Belt apps (set in lambda/config/environment.rb).
  #
  #   Belt.configure do |config|
  #     config.default_format = :json  # or :html
  #   end
  #
  # Note: infrastructure/<env>/belt.rb uses a separate sandboxed DSL for CLI
  # deploy/backup settings — it does not share this object.
  class Configuration
    VALID_FORMATS = %i[json html].freeze

    def initialize
      @default_format = :json
    end

    attr_reader :default_format

    def default_format=(value)
      format = value.to_sym
      unless VALID_FORMATS.include?(format)
        raise ArgumentError, "default_format must be :json or :html (got #{value.inspect})"
      end

      @default_format = format
    end
  end
end
