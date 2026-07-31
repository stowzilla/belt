# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Security hardening' do
  describe Belt::Helpers::CorsOrigin do
    before { described_class.reset! }
    after { described_class.reset! }

    describe '.valid_origin?' do
      it 'accepts valid https origins' do
        expect(described_class.valid_origin?('https://example.com')).to be true
      end

      it 'accepts valid http origins' do
        expect(described_class.valid_origin?('http://localhost:3000')).to be true
      end

      it 'accepts origins with ports' do
        expect(described_class.valid_origin?('https://app.example.com:8443')).to be true
      end

      it 'rejects nil' do
        expect(described_class.valid_origin?(nil)).to be false
      end

      it 'rejects empty strings' do
        expect(described_class.valid_origin?('')).to be false
      end

      it 'rejects origins exceeding max length' do
        long_origin = "https://#{'a' * 300}.com"
        expect(described_class.valid_origin?(long_origin)).to be false
      end

      it 'rejects origins with path components' do
        expect(described_class.valid_origin?('https://example.com/path')).to be false
      end

      it 'rejects origins with query strings' do
        expect(described_class.valid_origin?('https://example.com?foo=bar')).to be false
      end

      it 'rejects origins with fragments' do
        expect(described_class.valid_origin?('https://example.com#section')).to be false
      end

      it 'rejects origins with user info (@)' do
        expect(described_class.valid_origin?('https://user@example.com')).to be false
      end

      it 'rejects non-HTTP schemes' do
        expect(described_class.valid_origin?('ftp://example.com')).to be false
      end

      it 'rejects origins with whitespace' do
        expect(described_class.valid_origin?('https://example .com')).to be false
      end

      it 'rejects javascript: scheme attempts' do
        expect(described_class.valid_origin?('javascript:alert(1)')).to be false
      end
    end

    describe '.matches_allowed?' do
      it 'matches exact origins' do
        expect(described_class.matches_allowed?('https://app.example.com', ['https://app.example.com'])).to be true
      end

      it 'does not match different origins' do
        expect(described_class.matches_allowed?('https://evil.com', ['https://app.example.com'])).to be false
      end

      context 'with wildcard patterns' do
        let(:allowed) { ['https://*.example.com'] }

        it 'matches valid subdomains' do
          expect(described_class.matches_allowed?('https://app.example.com', allowed)).to be true
        end

        it 'matches hyphenated subdomains' do
          expect(described_class.matches_allowed?('https://my-app.example.com', allowed)).to be true
        end

        it 'does not match multi-level subdomains via single wildcard' do
          # The wildcard [a-z0-9\-]+ does not match dots, so sub.app.example.com won't match
          expect(described_class.matches_allowed?('https://sub.app.example.com', allowed)).to be false
        end

        it 'does not match origins with special characters in subdomain' do
          expect(described_class.matches_allowed?('https://evil<script>.example.com', allowed)).to be false
        end

        it 'does not match unrelated domains with similar suffix' do
          expect(described_class.matches_allowed?('https://notexample.com', allowed)).to be false
        end
      end
    end

    describe '.resolve_origin' do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('CORS_ALLOWED_ORIGINS', nil).and_return('https://app.example.com')
      end

      it 'reflects valid matching origins' do
        expect(described_class.resolve_origin('https://app.example.com')).to eq('https://app.example.com')
      end

      it 'does not reflect invalid origins even if they match patterns' do
        allow(ENV).to receive(:fetch).with('CORS_ALLOWED_ORIGINS', nil).and_return('https://*.example.com')
        # Origin with path (invalid format) should not be reflected — falls back to wildcard '*'
        expect(described_class.resolve_origin('https://app.example.com/evil')).to eq('*')
      end

      it 'returns first allowed origin when request origin is nil' do
        expect(described_class.resolve_origin(nil)).to eq('https://app.example.com')
      end
    end
  end

  describe 'Response security headers' do
    let(:controller_class) do
      Class.new(BeltController::Base) do
        def test_action
          success_response({ ok: true })
        end

        def test_html
          html_response('<h1>Test</h1>')
        end
      end
    end

    let(:event) do
      {
        'httpMethod' => 'GET',
        'path' => '/test',
        'headers' => { 'Origin' => 'https://app.example.com' },
        'pathParameters' => {},
        'queryStringParameters' => {},
        'requestContext' => { 'authorizer' => { 'claims' => { 'sub' => 'user-1' } } }
      }
    end

    before do
      Belt::Helpers::CorsOrigin.reset!
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('CORS_ALLOWED_ORIGINS', nil).and_return('https://app.example.com')
    end

    after { Belt::Helpers::CorsOrigin.reset! }

    it 'includes X-Content-Type-Options: nosniff in JSON responses' do
      controller = controller_class.new(event: event, body: {})
      result = controller.dispatch(:test_action)
      expect(result[:headers]['X-Content-Type-Options']).to eq('nosniff')
    end

    it 'includes Vary: Origin in JSON responses' do
      controller = controller_class.new(event: event, body: {})
      result = controller.dispatch(:test_action)
      expect(result[:headers]['Vary']).to eq('Origin')
    end

    it 'includes X-Frame-Options in HTML responses' do
      controller = controller_class.new(event: event, body: {})
      result = controller.dispatch(:test_html)
      expect(result[:headers]['X-Frame-Options']).to eq('DENY')
    end

    it 'includes X-Content-Type-Options in HTML responses' do
      controller = controller_class.new(event: event, body: {})
      result = controller.dispatch(:test_html)
      expect(result[:headers]['X-Content-Type-Options']).to eq('nosniff')
    end

    it 'includes Referrer-Policy in HTML responses' do
      controller = controller_class.new(event: event, body: {})
      result = controller.dispatch(:test_html)
      expect(result[:headers]['Referrer-Policy']).to eq('strict-origin-when-cross-origin')
    end
  end

  describe Belt::ActionRouter do
    let(:routes) do
      [
        { verb: 'GET', path: '/posts', controller: 'posts', action: 'index' },
        { verb: 'GET', path: '/posts/{post_id}', controller: 'posts', action: 'show' }
      ]
    end
    let(:router) { described_class.new(routes: routes, namespace: 'api') }

    describe 'controller name validation' do
      it 'accepts simple controller names' do
        expect(router.send(:valid_controller_name?, 'posts')).to be true
      end

      it 'accepts underscored controller names' do
        expect(router.send(:valid_controller_name?, 'user_profiles')).to be true
      end

      it 'accepts single-level nested controller names' do
        expect(router.send(:valid_controller_name?, 'admin/posts')).to be true
      end

      it 'rejects path traversal attempts' do
        expect(router.send(:valid_controller_name?, '../etc/passwd')).to be false
      end

      it 'rejects double dot sequences' do
        expect(router.send(:valid_controller_name?, 'admin/../config')).to be false
      end

      it 'rejects absolute paths' do
        expect(router.send(:valid_controller_name?, '/etc/passwd')).to be false
      end

      it 'rejects backslash paths' do
        expect(router.send(:valid_controller_name?, 'admin\\posts')).to be false
      end

      it 'rejects deeply nested paths' do
        expect(router.send(:valid_controller_name?, 'a/b/c')).to be false
      end

      it 'rejects names with special characters' do
        expect(router.send(:valid_controller_name?, 'posts;rm -rf')).to be false
      end

      it 'rejects empty names' do
        expect(router.send(:valid_controller_name?, '')).to be false
      end

      it 'rejects nil names' do
        expect(router.send(:valid_controller_name?, nil)).to be false
      end

      it 'rejects names starting with numbers' do
        expect(router.send(:valid_controller_name?, '123posts')).to be false
      end

      it 'rejects uppercase names' do
        expect(router.send(:valid_controller_name?, 'Posts')).to be false
      end
    end
  end

  describe 'Request body size limit' do
    it 'defines MAX_REQUEST_BODY_SIZE constant' do
      expect(Belt::Helpers::Response::MAX_REQUEST_BODY_SIZE).to eq(10 * 1024 * 1024)
    end
  end
end
