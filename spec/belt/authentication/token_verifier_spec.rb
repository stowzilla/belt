# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe Belt::Authentication::TokenVerifier do
  let(:issuer) { 'https://cognito-idp.us-east-1.amazonaws.com/us-east-1_pool' }
  let(:client_id) { 'app-client-id' }
  let(:pool_key) { OpenSSL::PKey::RSA.new(2048) }
  let(:kid) { 'pool-key-1' }

  before { described_class.store_keys(issuer, kid => pool_key.public_key) }
  after { described_class.reset! }

  def segment(value)
    Base64.urlsafe_encode64(value.is_a?(String) ? value : JSON.generate(value), padding: false)
  end

  def claims(overrides = {})
    {
      'sub' => 'user-sub', 'email' => 'a@b.com', 'iss' => issuer, 'aud' => client_id,
      'token_use' => 'id', 'exp' => Time.now.to_i + 600
    }.merge(overrides).compact
  end

  def signed_token(payload = claims, key: pool_key, header: { 'alg' => 'RS256', 'kid' => kid })
    signed = "#{segment(header)}.#{segment(payload)}"
    "#{signed}.#{segment(key.sign('SHA256', signed))}"
  end

  def verify(token, issuer: self.issuer, client_ids: [client_id])
    described_class.verify(token, issuer: issuer, client_ids: client_ids)
  end

  it "returns the claims of a token signed by the pool for the app's client" do
    expect(verify(signed_token)).to include('sub' => 'user-sub', 'email' => 'a@b.com')
  end

  it 'accepts any of several configured clients' do
    expect(verify(signed_token, client_ids: %w[mobile-client app-client-id])).to include('sub' => 'user-sub')
  end

  describe 'signature' do
    # The attack: a three-part token the caller wrote themselves.
    it 'rejects a token with a made-up signature' do
      forged = "#{segment('alg' => 'RS256', 'kid' => kid)}.#{segment(claims)}.#{segment('signature')}"

      expect(verify(forged)).to be_nil
    end

    it 'rejects a token signed by some other key' do
      expect(verify(signed_token(key: OpenSSL::PKey::RSA.new(2048)))).to be_nil
    end

    it 'rejects a payload swapped under a real signature' do
      header, _payload, signature = signed_token.split('.')
      tampered = "#{header}.#{segment(claims('sub' => 'victim-sub'))}.#{signature}"

      expect(verify(tampered)).to be_nil
    end

    it 'rejects alg none' do
      unsigned = "#{segment('alg' => 'none', 'kid' => kid)}.#{segment(claims)}."

      expect(verify(unsigned)).to be_nil
    end

    # HS256 signed with the public key as the secret — the classic confusion attack.
    it 'rejects HS256' do
      signed = "#{segment('alg' => 'HS256', 'kid' => kid)}.#{segment(claims)}"
      mac = OpenSSL::HMAC.digest('SHA256', pool_key.public_key.to_pem, signed)

      expect(verify("#{signed}.#{segment(mac)}")).to be_nil
    end

    it 'rejects a token naming no key' do
      expect(verify(signed_token(header: { 'alg' => 'RS256' }))).to be_nil
    end
  end

  describe 'claims' do
    it 'rejects an expired token' do
      expect(verify(signed_token(claims('exp' => Time.now.to_i - 60)))).to be_nil
    end

    it 'rejects a token with no expiry' do
      expect(verify(signed_token(claims('exp' => nil)))).to be_nil
    end

    it 'rejects a token from another issuer' do
      expect(verify(signed_token(claims('iss' => 'https://evil.example.com')))).to be_nil
    end

    it 'rejects a token issued for another client' do
      expect(verify(signed_token(claims('aud' => 'someone-elses-client')))).to be_nil
    end

    # Access tokens carry no email or name (and no aud), so they must not stand in.
    it 'rejects an access token' do
      expect(verify(signed_token(claims('token_use' => 'access')))).to be_nil
    end

    it 'rejects a token with no token_use' do
      expect(verify(signed_token(claims('token_use' => nil)))).to be_nil
    end

    it 'rejects a payload that is not an object' do
      expect(verify(signed_token([1, 2, 3]))).to be_nil
    end
  end

  # No pool or no client configured means there is nothing to verify against.
  # A validly signed token still must not come back as claims.
  describe 'without configuration' do
    it 'is nil without an issuer' do
      expect(verify(signed_token, issuer: nil)).to be_nil
      expect(verify(signed_token, issuer: '')).to be_nil
    end

    it 'is nil without a client id' do
      expect(verify(signed_token, client_ids: nil)).to be_nil
      expect(verify(signed_token, client_ids: [])).to be_nil
      expect(verify(signed_token, client_ids: [''])).to be_nil
    end
  end

  it 'is nil for anything that is not a JWT, rather than raising' do
    expect(verify('fp_live_abc123')).to be_nil
    expect(verify('two.parts')).to be_nil
    expect(verify('!!.!!.!!')).to be_nil
    expect(verify(nil)).to be_nil
  end

  describe 'key set' do
    def jwk(key, kid)
      encode = ->(bn) { Base64.urlsafe_encode64(bn.to_s(2), padding: false) }
      { 'kty' => 'RSA', 'kid' => kid, 'n' => encode.call(key.n), 'e' => encode.call(key.e) }
    end

    def jwks_response(*jwks)
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      allow(response).to receive(:body).and_return(JSON.generate('keys' => jwks))
      response
    end

    before { described_class.reset! }

    it "fetches the pool's JWKS from the configured issuer, once" do
      expect(Net::HTTP).to receive(:start)
        .with('cognito-idp.us-east-1.amazonaws.com', 443, hash_including(use_ssl: true))
        .once.and_return(jwks_response(jwk(pool_key, kid)))

      2.times { expect(verify(signed_token)).to include('sub' => 'user-sub') }
    end

    # A caller inventing key ids must not buy an outbound fetch per request.
    it 'does not refetch for every unknown kid' do
      expect(Net::HTTP).to receive(:start).once.and_return(jwks_response(jwk(pool_key, kid)))

      3.times { |i| expect(verify(signed_token(header: { 'alg' => 'RS256', 'kid' => "bogus-#{i}" }))).to be_nil }
    end

    it 'refetches for an unknown kid once the interval has passed, picking up a rotated key' do
      rotated = OpenSSL::PKey::RSA.new(2048)
      allow(Net::HTTP).to receive(:start).and_return(
        jwks_response(jwk(pool_key, kid)),
        jwks_response(jwk(pool_key, kid), jwk(rotated, 'pool-key-2'))
      )
      new_token = signed_token(key: rotated, header: { 'alg' => 'RS256', 'kid' => 'pool-key-2' })

      expect(verify(new_token)).to be_nil

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      allow(Process).to receive(:clock_gettime).and_return(now + described_class::REFETCH_INTERVAL + 1)

      expect(verify(new_token)).to include('sub' => 'user-sub')
    end

    # The real request path, against a throwaway local server: fetch, JWK → RSA key,
    # verify. Nothing here is stubbed.
    it 'verifies against a JWKS served over HTTP' do
      body = JSON.generate('keys' => [jwk(pool_key, kid)])
      server = TCPServer.new('127.0.0.1', 0)
      thread = Thread.new do
        client = server.accept
        request_line = client.gets
        nil until client.gets.strip.empty?
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
        request_line
      end
      local_issuer = "http://127.0.0.1:#{server.addr[1]}/us-east-1_pool"

      token = signed_token(claims('iss' => local_issuer))

      expect(verify(token, issuer: local_issuer)).to include('sub' => 'user-sub')
      expect(thread.value).to start_with('GET /us-east-1_pool/.well-known/jwks.json ')
    ensure
      server&.close
      thread&.kill
    end

    it 'is nil when the key set cannot be fetched' do
      allow(Net::HTTP).to receive(:start).and_raise(SocketError)

      expect(verify(signed_token)).to be_nil
    end
  end
end
