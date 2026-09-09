# frozen_string_literal: true

module Belt
  # Runtime configuration for Belt apps (set in lambda/config/environment.rb).
  #
  #   Belt.configure do |config|
  #     config.default_format = :json  # or :html
  #     config.authentication.user_class = 'Account'
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

    # Cognito identity settings — see Belt::Authentication::Configuration.
    # Resolved lazily so config can be set before the app's models are loaded.
    def authentication
      @authentication ||= Belt::Authentication::Configuration.new
    end

    def default_format=(value)
      format = value.to_sym
      unless VALID_FORMATS.include?(format)
        raise ArgumentError, "default_format must be :json or :html (got #{value.inspect})"
      end

      @default_format = format
    end
  end

  # Runtime configuration accessors live here, not in belt.rb, so that a single
  # subsystem can be required on its own (`require 'belt/authentication'`) and still
  # reach Belt.configuration. Test harnesses that shadow BeltController do exactly that.
  class << self
    # Runtime configuration (lambda/config/environment.rb). Separate from the
    # CLI sandboxed DSL in infrastructure/<env>/belt.rb.
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
