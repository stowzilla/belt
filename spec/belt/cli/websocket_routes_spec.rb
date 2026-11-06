# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'belt/cli/routes_command'

RSpec.describe Belt::CLI::RoutesCommand do
  let(:command) { described_class.new([]) }

  before do
    Belt.instance_variable_set(:@application, nil)
    command.instance_variable_set(:@table_inference, Belt::TableInference.new(nil))
  end

  it 'builds WebSocket records without injecting an HTTP welcome route' do
    dsl = Belt.application.routes.draw do
      gateway :live, type: :websocket do
        on :connect, to: 'live_events#connect', tables: [:live_connections]
        on :subscribe, to: 'live_events#subscribe'
      end
    end

    routes = command.send(:collect_routes, dsl)

    expect(routes.map { |route| route[:path] }).to eq(['$connect', 'subscribe'])
    expect(routes.first).to include(
      name: 'connect', verb: 'ON', route_type: 'websocket', route_key: '$connect',
      gateway: 'live', controller: 'live_events', action: 'connect', tables: ['live_connections']
    )
  end

  it 'writes WebSocket metadata to generated Ruby manifests' do
    route = {
      verb: 'ON', path: '$connect', gateway: 'live', lambda: 'live', controller: 'live_events',
      action: 'connect', auth: 'none', tables: ['live_connections'], route_type: 'websocket',
      route_key: '$connect'
    }

    content = command.send(:generate_ruby_content, [route], 'live')

    expect(content).to include('route_type: :websocket')
    expect(content).to include('route_key: "$connect"')
  end

  it 'separates WebSocket records from the legacy HTTP routes JSON array' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'config'))
      File.write(File.join(dir, 'config/routes.rb'), <<~RUBY)
        Belt.application.routes.draw do
          gateway :api do
            get '/health', to: 'health#show'
          end
          gateway :live, type: :websocket do
            on :connect, to: 'live_events#connect'
          end
        end
      RUBY

      output = Dir.chdir(dir) do
        capture_stdout { described_class.run(%w[-f json]) }
      end
      parsed = JSON.parse(output)

      expect(parsed.fetch('routes').map { |route| route['gateway'] }).to contain_exactly('api', 'api')
      expect(parsed.fetch('websocket_routes').first).to include(
        'route_type' => 'websocket', 'route_key' => '$connect', 'gateway' => 'live'
      )
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
