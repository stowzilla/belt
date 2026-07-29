# frozen_string_literal: true

require 'base64'

module Belt
  # Gem-embedded welcome controller that serves the default "it works!" page.
  # Resolved via the ActionRouter's Belt:: namespace fallback when no app-defined
  # WelcomeController exists. Gets replaced once the user defines their own root route.
  #
  # Dual format:
  #   - Browser / no Accept preference → HTML hero + stack check
  #   - Accept: application/json (SPA / apiClient) → JSON payload for the React shell
  #
  # The hero image (lib/belt/assets/belt-default.jpg) is the single source of truth —
  # HTML embeds it, and JSON returns the same bytes as a data URI so the SPA matches.
  class WelcomeController < BeltController::Base
    skip_before_action :authenticate!

    ASSETS_DIR = File.expand_path('../assets', __dir__)
    MODEL_HINT_CMD = 'belt generate model Post title content:text'

    def show
      @title = ENV.fetch('WELCOME_TITLE', 'Welcome to Belt')
      @subtitle = ENV.fetch('WELCOME_SUBTITLE', 'API Gateway → Lambda → DynamoDB — all connected.')
      @dynamodb_connected = dynamodb_connected?
      @model_hint_cmd = MODEL_HINT_CMD

      if wants_json?
        return success_response(welcome_payload)
      end

      @css = welcome_css
      @background_image = background_image_base64
      render
    end

    private

    def welcome_payload
      {
        title: @title,
        subtitle: @subtitle,
        # Same gem asset as the HTML welcome page — edit belt-default.jpg once.
        background_image: "data:image/jpeg;base64,#{background_image_base64}",
        stack: {
          api_gateway: true,
          lambda: true,
          dynamodb: @dynamodb_connected
        },
        # Empty account / no tables is fine — not an error. SPA uses this for tip UI.
        dynamodb_hint: @dynamodb_connected ? nil : "No tables yet — create one with: #{MODEL_HINT_CMD}",
        next_steps: [
          "Add a DynamoDB model: #{MODEL_HINT_CMD}",
          'Deploy: belt deploy',
          'This page will be replaced once you define your own root route.'
        ]
      }
    end

    # SPA apiClient and fetch(..., { headers: { Accept: "application/json" } })
    def wants_json?
      return true if params['format'].to_s == 'json'

      accept = header_value('Accept') || header_value('accept') || ''
      return false if accept.empty?

      # Prefer JSON when it's listed and not beaten by an explicit HTML preference
      json_q = accept_quality(accept, 'application/json')
      html_q = accept_quality(accept, 'text/html')
      json_q.positive? && json_q >= html_q
    end

    def header_value(name)
      headers = event.is_a?(Hash) ? event['headers'] : nil
      return nil unless headers.is_a?(Hash)

      headers[name] || headers[name.downcase] || headers[name.split('-').map(&:capitalize).join('-')]
    end

    def accept_quality(accept, media_type)
      accept.split(',').each do |part|
        type, *params = part.strip.split(';').map(&:strip)
        # Exact type only — do not treat */* as JSON (curl/browsers send that by default)
        next unless type == media_type

        q = 1.0
        params.each do |p|
          q = p.split('=', 2).last.to_f if p.start_with?('q=')
        end
        return q
      end
      0.0
    end

    def dynamodb_connected?
      return false unless defined?(Aws::DynamoDB::Client)

      client = Aws::DynamoDB::Client.new
      client.list_tables(limit: 1)
      true
    rescue StandardError
      false
    end

    def welcome_css
      @welcome_css ||= File.read(File.join(ASSETS_DIR, 'welcome.css'))
    end

    def background_image_base64
      @background_image_base64 ||= Base64.strict_encode64(
        File.binread(File.join(ASSETS_DIR, 'belt-default.jpg'))
      )
    end
  end
end
