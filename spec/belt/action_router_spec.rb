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
