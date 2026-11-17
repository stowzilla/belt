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

  # Exception details in a response are for a developer's own machine. A deployed
  # stack is public whatever its environment is called.
  describe '#handle_error_and_respond' do
    let(:host) do
      Class.new do
        include Belt::Helpers::Response

        def log_error(*); end
      end.new
    end
    let(:error) do
      RuntimeError.new('table users-dev01 not found').tap { |e| e.set_backtrace(['app/models/user.rb:12']) }
    end

    def details_for(env)
      stub_const('ENV', ENV.to_h.except('BELT_VERBOSE_ERRORS', 'AWS_LAMBDA_FUNCTION_NAME').merge(env))
      JSON.parse(host.handle_error_and_respond(error, 'Something went wrong')[:body])['details']
    end

    it 'includes the exception outside Lambda in a dev environment' do
      expect(details_for('ENVIRONMENT' => 'dev'))
        .to include('type' => 'RuntimeError', 'backtrace' => ['app/models/user.rb:12'])
    end

    it 'leaves it out outside Lambda in prod' do
      expect(details_for('ENVIRONMENT' => 'prod')).to be_nil
    end

    it 'leaves it out on a deployed dev stack' do
      expect(details_for('ENVIRONMENT' => 'dev01', 'AWS_LAMBDA_FUNCTION_NAME' => 'app-dev01-api')).to be_nil
    end

    it 'includes it on a deployed stack that sets BELT_VERBOSE_ERRORS=true' do
      env = { 'ENVIRONMENT' => 'dev01', 'AWS_LAMBDA_FUNCTION_NAME' => 'app-dev01-api', 'BELT_VERBOSE_ERRORS' => 'true' }
      expect(details_for(env)).to include('message' => 'table users-dev01 not found')
    end

    it 'leaves it out everywhere when BELT_VERBOSE_ERRORS=false' do
      expect(details_for('ENVIRONMENT' => 'dev', 'BELT_VERBOSE_ERRORS' => 'false')).to be_nil
    end
  end
end
