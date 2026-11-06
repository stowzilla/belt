# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt::LiveController do
  subject(:controller) { controller_class.new(event: event, body: body) }

  let(:controller_class) do
    Class.new(described_class) do
      def subscribe
        success_response(
          connection_id: connection_id,
          route_key: route_key,
          query_token: query_params['token'],
          channel: params['channel'],
          frame_action: frame['action']
        )
      end
    end
  end
  let(:event) do
    {
      'requestContext' => { 'connectionId' => 'connection-1', 'routeKey' => 'subscribe' },
      'queryStringParameters' => { 'token' => 'token-1' }
    }
  end
  let(:body) { { 'action' => 'subscribe', 'channel' => 'match:42' } }

  it 'exposes WebSocket context and keeps the normal params lifecycle' do
    response = controller.dispatch(:subscribe)

    expect(JSON.parse(response[:body])).to eq(
      'connection_id' => 'connection-1',
      'route_key' => 'subscribe',
      'query_token' => 'token-1',
      'channel' => 'match:42',
      'frame_action' => 'subscribe'
    )
  end
end
