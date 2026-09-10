# frozen_string_literal: true

require 'spec_helper'

# A fake token exchanger that models exactly what Cognito enforces: it only hands back
# tokens if the code_verifier presented at exchange hashes to the challenge that was
# committed at begin. No network.
class FakeExchanger
  def initialize
    @expected_challenge = nil
    @refreshes = 0
  end

  attr_accessor :expected_challenge

  def exchange_code(code:, code_verifier:)
    if @expected_challenge &&
       !Belt::Authentication::SessionCookie::Pkce.matches?(verifier: code_verifier, challenge: @expected_challenge)
      raise 'PKCE verifier does not match challenge'
    end
    raise 'bad code' if code == 'bad'

    { access_token: "access-for-#{code}", id_token: 'id', refresh_token: "refresh-for-#{code}", expires_in: 3600 }
  end

  def refresh(refresh_token:)
    @refreshes += 1
    { access_token: "access-refreshed-#{@refreshes}-#{refresh_token}", id_token: 'id', expires_in: 3600 }
  end
end

RSpec.describe Belt::Authentication::SessionCookie::Flow do
  subject(:flow) { described_class }

  let(:store) { Belt::Authentication::SessionCookie::MemoryStore.new }
  let(:exchanger) { FakeExchanger.new }
  let(:subject_id) { 'sub-123' }

  before { store.register_subject(subject_id, credential_revision: 0) }

  def begin_sign_in(secure: true)
    flow.begin(
      hosted_ui_domain: 'app.auth.us-east-1.amazoncognito.com',
      client_id: 'client-abc',
      redirect_uri: 'https://app.example.com/auth/callback',
      secure: secure
    )
  end

  describe 'guarantee 1: authorization code flow with PKCE' do
    it 'builds a code-flow authorize URL carrying an S256 challenge, not the verifier' do
      begun = begin_sign_in
      url = begun[:authorize_url]

      expect(url).to include('response_type=code')
      expect(url).to include('code_challenge_method=S256')
      expect(url).to include("code_challenge=#{Belt::Authentication::SessionCookie::Pkce.challenge(begun[:code_verifier])}")
      expect(url).not_to include(begun[:code_verifier])
    end

    it 'refuses to exchange a code without the matching verifier' do
      begun = begin_sign_in
      exchanger.expected_challenge = Belt::Authentication::SessionCookie::Pkce.challenge(begun[:code_verifier])

      expect do
        flow.complete(
          code: 'authcode', returned_state: begun[:state], cookie_state: begun[:state],
          code_verifier: 'a-different-verifier-entirely', subject: subject_id,
          token_exchanger: exchanger, store: store
        )
      end.to raise_error(described_class::ExchangeError)
    end
  end

  describe 'guarantee 2: refresh held server-side' do
    it 'returns the refresh token only under :server_side, never in a browser cookie' do
      begun = begin_sign_in
      result = flow.complete(
        code: 'authcode', returned_state: begun[:state], cookie_state: begun[:state],
        code_verifier: begun[:code_verifier], subject: subject_id,
        token_exchanger: exchanger, store: store
      )

      expect(result[:server_side][:refresh_token]).to eq('refresh-for-authcode')
      cookie_blob = result[:browser_cookies].join("\n")
      expect(cookie_blob).not_to include('refresh-for-authcode')
      expect(cookie_blob).not_to match(/refresh/i)
    end

    it 'persists the refresh token in the store and not on the client' do
      begun = begin_sign_in
      result = flow.complete(
        code: 'authcode', returned_state: begun[:state], cookie_state: begun[:state],
        code_verifier: begun[:code_verifier], subject: subject_id,
        token_exchanger: exchanger, store: store
      )
      stored = store.load_session(result[:session_id])
      expect(stored[:refresh_token]).to eq('refresh-for-authcode')
    end
  end

  describe 'guarantee 3: Secure, HttpOnly, SameSite cookies' do
    it 'marks every emitted cookie Secure, HttpOnly and SameSite' do
      begun = begin_sign_in
      result = flow.complete(
        code: 'authcode', returned_state: begun[:state], cookie_state: begun[:state],
        code_verifier: begun[:code_verifier], subject: subject_id,
        token_exchanger: exchanger, store: store
      )

      (begun[:cookies] + result[:browser_cookies]).each do |cookie|
        expect(cookie).to include('Secure')
        expect(cookie).to include('HttpOnly')
        expect(cookie).to match(/SameSite=/)
      end
    end
  end

  describe 'guarantee 4: no bearer credential in a URL' do
    it 'raises if a URL would carry a token query param' do
      expect { flow.assert_no_bearer_in_url!('https://x/cb?id_token=abc') }
        .to raise_error(described_class::BearerInUrlError)
    end

    it 'the browser only ever holds the opaque session id, not a token' do
      begun = begin_sign_in
      result = flow.complete(
        code: 'authcode', returned_state: begun[:state], cookie_state: begun[:state],
        code_verifier: begun[:code_verifier], subject: subject_id,
        token_exchanger: exchanger, store: store
      )
      session_cookie = result[:browser_cookies].find { |c| c.start_with?('belt_session=') }
      expect(session_cookie).to include(result[:session_id])
      expect(result[:browser_cookies].join).not_to include('access-for-authcode')
    end
  end

  describe 'guarantee 5: expiry and revocation' do
    def establish
      begun = begin_sign_in
      flow.complete(
        code: 'authcode', returned_state: begun[:state], cookie_state: begun[:state],
        code_verifier: begun[:code_verifier], subject: subject_id,
        token_exchanger: exchanger, store: store
      )
    end

    it 'authenticates a fresh session' do
      established = establish
      resolved = flow.authenticate(session_id: established[:session_id], store: store)
      expect(resolved[:subject]).to eq(subject_id)
    end

    it 'refuses an expired session' do
      established = establish
      future = -> { (Time.now + (400 * 24 * 60 * 60)).utc }
      expect { flow.authenticate(session_id: established[:session_id], store: store, clock: future) }
        .to raise_error(described_class::SessionInvalidError, /expired/)
    end

    it 'fences every other session when one signs out' do
      first = establish
      second = establish

      flow.revoke(session_id: first[:session_id], store: store)

      # The signed-out session is gone…
      expect { flow.authenticate(session_id: first[:session_id], store: store) }
        .to raise_error(described_class::SessionInvalidError)
      # …and the other live session is fenced on its next read.
      expect { flow.authenticate(session_id: second[:session_id], store: store) }
        .to raise_error(described_class::SessionInvalidError, /revoked/)
    end

    it 'is idempotent on a double sign-out' do
      established = establish
      flow.revoke(session_id: established[:session_id], store: store)
      expect { flow.revoke(session_id: established[:session_id], store: store) }.not_to raise_error
    end
  end

  describe 'CSRF state binding' do
    it 'rejects a callback whose state does not match the sign-in' do
      begun = begin_sign_in
      expect do
        flow.complete(
          code: 'authcode', returned_state: 'forged', cookie_state: begun[:state],
          code_verifier: begun[:code_verifier], subject: subject_id,
          token_exchanger: exchanger, store: store
        )
      end.to raise_error(described_class::InvalidHandshakeError, /state/)
    end
  end

  describe 'refresh' do
    it 'mints a new access token from the server-side refresh token' do
      begun = begin_sign_in
      established = flow.complete(
        code: 'authcode', returned_state: begun[:state], cookie_state: begun[:state],
        code_verifier: begun[:code_verifier], subject: subject_id,
        token_exchanger: exchanger, store: store
      )
      refreshed = flow.refresh(session_id: established[:session_id], token_exchanger: exchanger, store: store)
      expect(refreshed[:tokens][:access_token]).to include('access-refreshed')
    end
  end
end
