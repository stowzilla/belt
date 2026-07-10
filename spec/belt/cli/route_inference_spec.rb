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
    it 'uses gateway name for non-resource single-segment routes' do
      route = build_route(:post, '/webhook')
      gateway = build_gateway(:ebay_events)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('ebay_events')
    end

    it 'uses gateway name for standalone action routes' do
      route = build_route(:post, '/signup')
      gateway = build_gateway(:onboarding)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('onboarding')
    end

    it 'uses gateway name for hyphenated standalone routes' do
      route = build_route(:post, '/resend-verification')
      gateway = build_gateway(:onboarding)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('onboarding')
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

    it 'uses gateway name for hyphenated standalone routes too' do
      route = build_route(:get, '/upload-image')
      gateway = build_gateway(:customer)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('customer')
    end

    it 'uses first segment for multi-segment non-resource routes' do
      route = build_route(:get, '/items/:id/upload-image')
      gateway = build_gateway(:customer)
      expect(test_class.send(:infer_controller, route, gateway)).to eq('items')
    end
  end
end
