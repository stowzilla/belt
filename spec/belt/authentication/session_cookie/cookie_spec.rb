# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt::Authentication::SessionCookie::Cookie do
  describe '.set' do
    it 'emits Secure, HttpOnly and SameSite by default' do
      cookie = described_class.set('belt_session', 'abc123', max_age: 60)
      expect(cookie).to eq('belt_session=abc123; Path=/; Max-Age=60; SameSite=Lax; Secure; HttpOnly')
    end

    it 'url-escapes the value' do
      cookie = described_class.set('k', 'a b/c', max_age: 1)
      expect(cookie).to include('k=a+b%2Fc')
    end

    it 'omits Secure when told to (for a local http dev origin)' do
      expect(described_class.set('k', 'v', max_age: 1, secure: false)).not_to include('Secure')
    end
  end

  describe '.clear' do
    it 'expires immediately with Max-Age=0' do
      expect(described_class.clear('belt_session')).to include('Max-Age=0', 'HttpOnly')
    end
  end

  describe '.parse' do
    it 'reads a Cookie header into a hash and unescapes values' do
      parsed = described_class.parse('belt_session=abc123; belt_oauth_state=a%2Fb')
      expect(parsed).to eq('belt_session' => 'abc123', 'belt_oauth_state' => 'a/b')
    end

    it 'tolerates a nil header' do
      expect(described_class.parse(nil)).to eq({})
    end
  end
end
