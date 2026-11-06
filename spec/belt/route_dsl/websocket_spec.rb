# frozen_string_literal: true

require 'spec_helper'
require 'belt/route_dsl'

RSpec.describe 'Route DSL: WebSocket gateways' do
  before { Belt.instance_variable_set(:@application, nil) }

  def gateway(&block)
    Belt.application.routes.draw(&block).api_gateways.first
  end

  it 'keeps REST as the default gateway type' do
    result = gateway do
      gateway :api do
        get '/health', to: 'health#show'
      end
    end

    expect(result.type).to eq(:rest)
    expect(result).not_to be_websocket
  end

  it 'normalizes lifecycle and custom route keys' do
    result = gateway do
      gateway :live, type: :websocket do
        on :connect, to: 'live_events#connect', tables: [:live_connections]
        on :subscribe, to: 'live_events#join'
      end
    end

    connect, subscribe = result.routes
    expect(connect).to have_attributes(method: 'ON', path: '$connect', route_key: '$connect',
                                       route_type: :websocket, controller: 'live_events', action: 'connect')
    expect(connect.tables).to eq([:live_connections])
    expect(connect.cors).to be(false)
    expect(subscribe).to have_attributes(path: 'subscribe', route_key: 'subscribe', action: 'join')
  end

  it 'inherits function, auth, and tables options' do
    result = gateway do
      gateway :live, type: :websocket, auth: :none, tables: [:live_connections] do
        function :socket do
          on :default, to: 'live_events#fallback', auth: :custom
        end
      end
    end

    expect(result.routes.first).to have_attributes(lambda: 'socket', auth: :custom,
                                                   tables: [:live_connections])
  end

  it 'rejects HTTP routes on WebSocket gateways and on routes on REST gateways' do
    expect do
      gateway { gateway(:live, type: :websocket) { get '/wrong', to: 'wrong#show' } }
    end.to raise_error(ArgumentError, /only accepts `on` routes/)

    expect do
      gateway { gateway(:api) { on :connect, to: 'live_events#connect' } }
    end.to raise_error(ArgumentError, /only accepts HTTP routes/)
  end

  it 'rejects unknown gateway types and malformed route keys' do
    expect { gateway { gateway(:live, type: :udp) } }.to raise_error(ArgumentError, /gateway type/)
    expect do
      gateway { gateway(:live, type: :websocket) { on 'bad route', to: 'live_events#fallback' } }
    end.to raise_error(ArgumentError, /invalid WebSocket route key/)
  end
end
