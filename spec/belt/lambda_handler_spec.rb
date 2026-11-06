# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt::LambdaHandler do
  subject(:handler) { handler_class.new }

  let(:logger) { instance_double(LambdaLoadout::Logger, info: nil, error: nil) }
  let(:metrics) { instance_double(LambdaLoadout::Metrics) }
  let(:handler_class) do
    log = logger
    metric_sink = metrics
    Class.new do
      include Belt::LambdaHandler

      attr_reader :received

      define_method(:init_observability) do |**_options|
        @logger = log
        @metrics = metric_sink
      end

      def execute(path:, body:, event:)
        @received = { path: path, body: body, event: event }
        { statusCode: 200, body: JSON.generate(ok: true) }
      end
    end
  end
  let(:context) { instance_double('LambdaContext', function_name: 'app-live') }

  before do
    allow(LambdaLoadout).to receive(:with_logging_and_metrics).and_yield
  end

  it 'passes a parsed WebSocket frame and route key to execute' do
    event = {
      'requestContext' => {
        'connectionId' => 'connection-1', 'routeKey' => 'subscribe',
        'identity' => { 'sourceIp' => '127.0.0.1' }
      },
      'body' => JSON.generate(action: 'subscribe', channel: 'match:42')
    }

    response = handler.lambda_handler(event: event, context: context)

    expect(response[:statusCode]).to eq(200)
    expect(handler.received).to include(path: 'subscribe', body: { 'action' => 'subscribe', 'channel' => 'match:42' })
    expect(logger).to have_received(:info).with('Lambda invoked', hash_including(route_key: 'subscribe',
                                                                                 connection_id: 'connection-1'))
  end

  it 'treats a missing lifecycle body as an empty frame' do
    event = { 'requestContext' => { 'connectionId' => 'connection-1', 'routeKey' => '$connect' } }

    handler.lambda_handler(event: event, context: context)

    expect(handler.received).to include(path: '$connect', body: {})
  end

  it 'does not apply HTTP OPTIONS preflight handling to a WebSocket route' do
    event = {
      'httpMethod' => 'OPTIONS',
      'requestContext' => { 'connectionId' => 'connection-1', 'routeKey' => '$default' }
    }

    handler.lambda_handler(event: event, context: context)

    expect(handler.received[:path]).to eq('$default')
  end

  it 'keeps the existing HTTP path contract' do
    event = { 'httpMethod' => 'POST', 'path' => '/posts', 'requestContext' => {}, 'body' => '{"title":"Post"}' }

    handler.lambda_handler(event: event, context: context)

    expect(handler.received).to include(path: '/posts', body: { 'title' => 'Post' })
  end
end
