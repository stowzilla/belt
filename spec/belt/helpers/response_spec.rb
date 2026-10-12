# frozen_string_literal: true

require 'spec_helper'
require 'json'

# success_response must deep-serialize its body the same way implicit assigns do.
# Regression: an explicit `success_response(thing: @model)` used to fall straight
# through to JSON.generate on the bare model, emitting "#<Thing:0x...>" and
# rendering a blank detail page in the client.
RSpec.describe Belt::Helpers::Response do
  # A stand-in for an ActiveItem model: responds to #to_h, has a noisy #to_s.
  let(:model_class) do
    Class.new do
      def initialize(attrs)
        @attrs = attrs
      end

      def to_h
        @attrs
      end

      def to_s
        "#<FakeModel:0x#{object_id.to_s(16)}>"
      end
    end
  end

  context 'when mixed into a controller (serializer available)' do
    let(:controller_class) do
      Class.new(BeltController::Base) do
        attr_writer :payload

        def show
          success_response(thing: @payload)
        end
      end
    end

    let(:event) do
      {
        'httpMethod' => 'GET',
        'path' => '/things/1',
        'headers' => {},
        'pathParameters' => {},
        'queryStringParameters' => {},
        'requestContext' => { 'authorizer' => { 'claims' => { 'sub' => 'user-1' } } }
      }
    end

    it 'serializes a bare model in the body to its attributes, not its #to_s' do
      controller = controller_class.new(event: event, body: {})
      controller.payload = model_class.new(title: 'QR label', slug: 'print_qr')

      result = controller.dispatch(:show)
      parsed = JSON.parse(result[:body])

      expect(parsed['thing']).to eq('title' => 'QR label', 'slug' => 'print_qr')
      expect(result[:body]).not_to include('#<')
    end

    it 'serializes models nested inside arrays' do
      controller = controller_class.new(event: event, body: {})
      controller.payload = [model_class.new(id: 1), model_class.new(id: 2)]

      result = controller.dispatch(:show)
      parsed = JSON.parse(result[:body])

      expect(parsed['thing']).to eq([{ 'id' => 1 }, { 'id' => 2 }])
    end

    it 'leaves plain hashes untouched' do
      controller = controller_class.new(event: event, body: {})
      controller.payload = { already: 'json' }

      result = controller.dispatch(:show)
      parsed = JSON.parse(result[:body])

      expect(parsed['thing']).to eq('already' => 'json')
    end
  end

  context 'when included standalone (no serializer mixed in)' do
    let(:bare_host) do
      Class.new do
        include Belt::Helpers::Response
      end
    end

    it 'falls back to the raw body instead of raising NoMethodError' do
      result = bare_host.new.success_response({ ok: true })
      expect(JSON.parse(result[:body])).to eq('ok' => true)
    end
  end
end
