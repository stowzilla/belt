# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/routes_command/route_inference'
require 'belt/route_dsl'

RSpec.describe Belt::CLI::RoutesCommand::RouteInference do
  let(:test_class) { Class.new { include Belt::CLI::RoutesCommand::RouteInference }.new }

  def build_route(method, path, options = {})
    Belt::Route.new(method, path, options)
  end

  def build_gateway(name)
    Belt::ApiGateway.new(name)
  end

  describe '#infer_controller' do
    it 'uses path segment for single-segment routes' do
      route = build_route(:post, '/webhook')
      gateway = build_gateway(:ebay_events)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('webhook')
    end

    it 'uses path segment even when lambda matches gateway' do
      route = build_route(:get, '/unsubscribe')
      gateway = build_gateway(:customer)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('unsubscribe')
    end

    it 'returns gateway name when path has no non-param segments' do
      route = build_route(:get, '/:id')
      gateway = build_gateway(:customer)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('customer')
    end

    it 'uses first path segment for multi-segment routes' do
      route = build_route(:get, '/items/:id/details')
      gateway = build_gateway(:customer)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('items')
    end

    it 'returns explicit controller when set' do
      route = build_route(:get, '/webhook', controller: 'operations')
      gateway = build_gateway(:customer)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('operations')
    end

    it 'handles hyphenated paths' do
      route = build_route(:get, '/upload-image')
      gateway = build_gateway(:customer)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('upload_image')
    end
  end
end
