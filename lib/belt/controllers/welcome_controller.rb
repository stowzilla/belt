# frozen_string_literal: true

require 'base64'

module Belt
  # Gem-embedded welcome controller that serves the default "it works!" page.
  # Resolved via the ActionRouter's Belt:: namespace fallback when no app-defined
  # WelcomeController exists. Gets replaced once the user defines their own root route.
  class WelcomeController < BeltController::Base
    skip_before_action :authenticate!

    ASSETS_DIR = File.expand_path('../assets', __dir__)

    def show
      @title = ENV.fetch('WELCOME_TITLE', 'Welcome to Belt')
      @subtitle = ENV.fetch('WELCOME_SUBTITLE', 'API Gateway → Lambda → DynamoDB — all connected.')
      @css = welcome_css
      @background_image = background_image_base64
      @dynamodb_connected = dynamodb_connected?

      render
    end

    private

    def dynamodb_connected?
      return false unless defined?(Aws::DynamoDB::Client)

      client = Aws::DynamoDB::Client.new
      client.list_tables(limit: 1)
      true
    rescue StandardError
      false
    end

    def welcome_css
      @welcome_css_content ||= File.read(File.join(ASSETS_DIR, 'welcome.css'))
    end

    def background_image_base64
      @background_image_content ||= Base64.strict_encode64(
        File.binread(File.join(ASSETS_DIR, 'belt-default.jpg'))
      )
    end
  end
end
