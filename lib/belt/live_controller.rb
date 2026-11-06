# frozen_string_literal: true

module Belt
  # Base controller for API Gateway WebSocket routes. It uses the normal Belt
  # callback, params, rescue, and response lifecycle while exposing the parts of
  # a WebSocket proxy event that actions need directly.
  class LiveController < BeltController::Base
    def connection_id
      event.dig('requestContext', 'connectionId')
    end

    def route_key
      event.dig('requestContext', 'routeKey')
    end

    def query_params
      event['queryStringParameters'] || {}
    end

    def frame
      body
    end
  end
end
