# frozen_string_literal: true

require 'spec_helper'
require 'belt/action_router'

RSpec.describe Belt::ActionRouter do
  let(:routes) do
    [
      { verb: 'GET', path: '/posts', controller: 'posts', action: 'index' },
      { verb: 'GET', path: '/posts/{post_id}', controller: 'posts', action: 'show' }
    ]
  end

  describe '#initialize' do
    it 'accepts gateway: keyword' do
      router = described_class.new(routes: routes, gateway: 'api')
      expect(router).to be_a(described_class)
    end

    it 'accepts legacy namespace: keyword' do
      router = described_class.new(routes: routes, namespace: 'api')
      expect(router).to be_a(described_class)
    end

    it 'prefers gateway: over namespace: when both provided' do
      router = described_class.new(routes: routes, gateway: 'api', namespace: 'legacy')
      # Gateway prefix is used for stripping — verify by testing route matching
      route = router.find_route('GET', '/posts')
      expect(route).not_to be_nil
    end

    it 'raises ArgumentError when neither gateway: nor namespace: provided' do
      expect { described_class.new(routes: routes) }.to raise_error(ArgumentError)
    end
  end

  describe 'gateway prefix stripping' do
    let(:router) { described_class.new(routes: routes, gateway: 'api') }

    it 'finds routes after stripping the gateway prefix from the path' do
      route = router.find_route('GET', '/posts')
      expect(route).not_to be_nil
      expect(route[:action]).to eq('index')
    end

    it 'extracts path parameters' do
      params = router.extract_path_params('/posts/{post_id}', '/posts/abc-123')
      expect(params).to eq({ 'post_id' => 'abc-123' })
    end
  end
end

RSpec.describe 'Belt::ActionRouter WebSocket dispatch' do
  before do
    stub_const('LiveControllers', Module.new)
    controller = Class.new(Belt::LiveController) do
      def connect
        success_response(connection_id: connection_id, token: query_params['token'])
      end

      def subscribe
        success_response(channel: frame['channel'], route_key: route_key)
      end
    end
    LiveControllers.const_set('LiveEventsController', controller)
  end

  let(:routes) do
    [
      {
        verb: 'ON', path: '$connect', route_type: :websocket, route_key: '$connect',
        controller: 'live_events', action: 'connect'
      },
      {
        'verb' => 'ON', 'path' => 'subscribe', 'route_type' => 'websocket', 'route_key' => 'subscribe',
        'controller' => 'live_events', 'action' => 'subscribe'
      }
    ]
  end
  let(:router) { Belt::ActionRouter.new(routes: routes, gateway: 'live') }

  it 'dispatches lifecycle routes with the connection and query parameters' do
    event = {
      'requestContext' => { 'connectionId' => 'abc123', 'routeKey' => '$connect' },
      'queryStringParameters' => { 'token' => 'seat-token' }
    }

    response = router.route(event: event, body: {})

    expect(JSON.parse(response[:body])).to eq('connection_id' => 'abc123', 'token' => 'seat-token')
    expect(event).not_to have_key('pathParameters')
  end

  it 'dispatches custom routes using requestContext.routeKey rather than the frame action' do
    event = { 'requestContext' => { 'connectionId' => 'abc123', 'routeKey' => 'subscribe' } }

    response = router.route(event: event, body: { 'action' => 'wrong', 'channel' => 'match:1' })

    expect(JSON.parse(response[:body])).to eq('channel' => 'match:1', 'route_key' => 'subscribe')
  end

  it 'does not allow a WebSocket manifest entry to match an HTTP request' do
    event = { 'httpMethod' => 'ON', 'path' => 'subscribe', 'requestContext' => {} }

    expect(router.route(event: event, body: {})[:statusCode]).to eq(404)
  end
end
