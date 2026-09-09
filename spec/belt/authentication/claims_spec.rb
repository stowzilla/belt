# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt::Authentication::Claims do
  def event(headers: nil, authorizer_claims: nil)
    e = {}
    e['headers'] = headers if headers
    e['requestContext'] = { 'authorizer' => { 'claims' => authorizer_claims } } if authorizer_claims
    e
  end

  def id_token(claims)
    header = Base64.urlsafe_encode64('{"alg":"RS256"}', padding: false)
    payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
    "#{header}.#{payload}.signature"
  end

  describe '.from_event' do
    it 'prefers pre-verified API Gateway authorizer claims' do
      claims = described_class.from_event(event(authorizer_claims: { 'sub' => 'abc' }))

      expect(claims).to eq('sub' => 'abc')
    end

    it 'decodes the Authorization header when there is no authorizer' do
      token = id_token('sub' => 'xyz', 'email' => 'a@b.com')

      claims = described_class.from_event(event(headers: { 'Authorization' => "Bearer #{token}" }))

      expect(claims['sub']).to eq('xyz')
    end

    it 'accepts a lowercased header name' do
      token = id_token('sub' => 'xyz')

      claims = described_class.from_event(event(headers: { 'authorization' => "Bearer #{token}" }))

      expect(claims['sub']).to eq('xyz')
    end

    it 'returns nil with no identity at all' do
      expect(described_class.from_event({})).to be_nil
    end

    # An app's own credential scheme (an API key, say) shares the Authorization
    # header. It must read as "no Cognito identity", not as an error.
    it 'returns nil for a bearer token that is not a JWT' do
      claims = described_class.from_event(event(headers: { 'Authorization' => 'Bearer fp_live_abc123' }))

      expect(claims).to be_nil
    end
  end

  describe '.decode' do
    it 'rejects an expired token' do
      token = id_token('sub' => 'x', 'exp' => Time.now.to_i - 60)

      expect(described_class.decode(token)).to be_nil
    end

    it 'accepts a token that has not expired' do
      token = id_token('sub' => 'x', 'exp' => Time.now.to_i + 600)

      expect(described_class.decode(token)).to include('sub' => 'x')
    end

    it 'rejects a token from another issuer' do
      token = id_token('sub' => 'x', 'iss' => 'https://evil.example.com')

      expect(described_class.decode(token, issuer: 'https://cognito-idp.us-east-1.amazonaws.com/pool')).to be_nil
    end

    it 'skips the issuer check when no issuer is configured' do
      token = id_token('sub' => 'x', 'iss' => 'https://anything')

      expect(described_class.decode(token)).to include('sub' => 'x')
    end

    # Access tokens carry no email or name, so they must not stand in for an ID token.
    it 'rejects an access token' do
      token = id_token('sub' => 'x', 'token_use' => 'access')

      expect(described_class.decode(token)).to be_nil
    end

    it 'returns nil for a malformed token rather than raising' do
      expect(described_class.decode('not.a.jwt')).to be_nil
      expect(described_class.decode('two.parts')).to be_nil
      expect(described_class.decode(nil)).to be_nil
    end
  end

  describe '.parse_groups' do
    it 'handles a JSON array from a raw token' do
      expect(described_class.parse_groups(%w[admins members])).to eq(%w[admins members])
    end

    # API Gateway flattens every claim to a string.
    it 'handles the flattened bracket form' do
      expect(described_class.parse_groups('[admins, members]')).to eq(%w[admins members])
    end

    it 'handles a bare comma-separated string' do
      expect(described_class.parse_groups('admins,members')).to eq(%w[admins members])
    end

    it 'is empty for nil' do
      expect(described_class.parse_groups(nil)).to eq([])
    end
  end

  describe '.truthy?' do
    it 'accepts both JSON and flattened booleans' do
      expect([true, 'true', 1, '1'].map { |v| described_class.truthy?(v) }).to all(be(true))
      expect([false, 'false', nil, '', 0].map { |v| described_class.truthy?(v) }).to all(be(false))
    end
  end
end
