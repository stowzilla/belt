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
      title = ENV.fetch('WELCOME_TITLE', 'Welcome to Belt')
      subtitle = ENV.fetch('WELCOME_SUBTITLE', 'API Gateway → Lambda → DynamoDB — all connected.')
      app_name = ENV.fetch('APP_NAME', 'my-app')

      html_response(render_welcome_page(title: title, subtitle: subtitle, app_name: app_name))
    end

    private

    def render_welcome_page(title:, subtitle:, app_name:)
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>#{escape_html(title)}</title>
          <style>#{welcome_css}</style>
        </head>
        <body>
          <div class="hero">
            <img src="data:image/png;base64,#{background_image_base64}" alt="Belt" class="hero-bg" />
            <div class="overlay">
              <h1>#{escape_html(title)}</h1>
              <p class="subtitle">#{escape_html(subtitle)}</p>
            </div>
          </div>
          <div class="container">
            <div class="stack-check">
              <div class="check-item check-pass">
                <span class="icon">✓</span>
                <span>API Gateway</span>
              </div>
              <div class="arrow">→</div>
              <div class="check-item check-pass">
                <span class="icon">✓</span>
                <span>Lambda</span>
              </div>
              <div class="arrow">→</div>
              #{dynamodb_check_html}
            </div>
            <div class="next-steps">
              <h2>Next Steps</h2>
              <ol>
                <li>Generate a resource: <code>belt g resource post title:string body:text</code></li>
                <li>Deploy: <code>belt deploy</code></li>
                <li>This page will be replaced once you define your own root route.</li>
              </ol>
            </div>
          </div>
        </body>
        </html>
      HTML
    end

    def dynamodb_check_html
      if dynamodb_connected?
        '<div class="check-item check-pass"><span class="icon">✓</span><span>DynamoDB</span></div>'
      else
        '<div class="check-item check-warn"><span class="icon">⚠</span><span>DynamoDB</span></div>'
      end
    end

    def dynamodb_connected?
      return false unless defined?(Aws::DynamoDB::Client)

      client = Aws::DynamoDB::Client.new
      client.list_tables(limit: 1)
      true
    rescue StandardError
      false
    end

    def escape_html(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
    end

    def welcome_css
      @welcome_css ||= File.read(File.join(ASSETS_DIR, 'welcome.css'))
    end

    def background_image_base64
      @background_image_base64 ||= Base64.strict_encode64(
        File.binread(File.join(ASSETS_DIR, 'belt-default.png'))
      )
    end
  end
end
