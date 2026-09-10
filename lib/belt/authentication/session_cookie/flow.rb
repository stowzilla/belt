# frozen_string_literal: true

require 'cgi'
require 'time'
require_relative 'pkce'
require_relative 'cookie'

module Belt
  module Authentication
    module SessionCookie
      # The session-cookie sign-in flow: authorization code + PKCE, refresh held
      # server-side, an opaque session id in an HttpOnly cookie, revocation by
      # credential-revision fencing.
      #
      # This is the alternative to holding a Cognito token in the browser. Its five
      # guarantees, each enforced here rather than assumed:
      #
      #   1. AUTHORIZATION CODE FLOW WITH PKCE. The SPA is a public client. #begin
      #      mints a PKCE verifier, derives its S256 challenge, and builds the Hosted-UI
      #      authorize URL carrying the challenge. #complete exchanges the code together
      #      with the original verifier. A `state` binds the callback to the sign-in.
      #
      #   2. REFRESH HELD SERVER-SIDE. The exchange returns access, id and refresh
      #      tokens. The refresh token is stored on the session record and NEVER leaves
      #      the server. #complete returns it only under :server_side, physically apart
      #      from :browser_cookies, so a controller cannot cookie it by accident.
      #
      #   3. SECURE, HTTPONLY, SAMESITE COOKIES. Every cookie emitted carries all three
      #      (see Cookie). HttpOnly is what keeps the session id out of browser storage.
      #
      #   4. NO BEARER CREDENTIAL IN A URL OR IN BROWSER STORAGE. The browser holds only
      #      an opaque session id (HttpOnly cookie). #assert_no_bearer_in_url! guards
      #      every URL this builds.
      #
      #   5. EXPIRY AND REVOCATION BEHAVE CORRECTLY. A session carries an absolute expiry
      #      and is bound to the subject's credential_revision at creation. #authenticate
      #      refuses an expired session or one whose bound revision is behind the current
      #      one. #revoke deletes the session AND bumps the revision, fencing every other
      #      live session on its next read — authorize-on-read, not cached.
      #
      # No AWS or network is touched here. Two seams are injected: `token_exchanger`
      # (trades a code or refresh token with Cognito for tokens) and `store` (persistence
      # — see MemoryStore for the contract).
      module Flow
        SESSION_COOKIE  = 'belt_session'
        VERIFIER_COOKIE = 'belt_pkce_verifier'
        STATE_COOKIE    = 'belt_oauth_state'

        HANDSHAKE_TTL = 600 # seconds; a sign-in that dawdles past this restarts.
        DEFAULT_SESSION_TTL = 30 * 24 * 60 * 60 # 30 days; match the refresh-token validity.
        DEFAULT_SCOPE = 'openid email'

        # Query keys that must never appear in a URL (guarantee 4).
        BEARER_QUERY_KEYS = %w[access_token id_token refresh_token token].freeze

        class Error < StandardError; end
        class InvalidHandshakeError < Error; end
        class ExchangeError < Error; end
        class SessionInvalidError < Error; end
        class BearerInUrlError < Error; end

        module_function

        # --- 1: begin a sign-in ------------------------------------------------------

        # @return [Hash] { authorize_url:, state:, code_verifier:, cookies: [set-cookie...] }
        def begin(hosted_ui_domain:, client_id:, redirect_uri:, scope: DEFAULT_SCOPE,
                  secure: true, same_site: Cookie::DEFAULT_SAME_SITE,
                  verifier: Pkce.verifier, state: Pkce.token)
          challenge = Pkce.challenge(verifier)

          query = {
            'response_type' => 'code',
            'client_id' => client_id,
            'redirect_uri' => redirect_uri,
            'scope' => scope,
            'state' => state,
            'code_challenge' => challenge,
            'code_challenge_method' => 'S256'
          }
          authorize_url = "https://#{hosted_ui_domain}/oauth2/authorize?#{encode_query(query)}"
          assert_no_bearer_in_url!(authorize_url)

          {
            authorize_url: authorize_url,
            state: state,
            code_verifier: verifier,
            cookies: [
              Cookie.set(VERIFIER_COOKIE, verifier, max_age: HANDSHAKE_TTL, secure: secure, same_site: same_site),
              Cookie.set(STATE_COOKIE, state, max_age: HANDSHAKE_TTL, secure: secure, same_site: same_site)
            ]
          }
        end

        # --- 2 + 3: complete the callback and establish a server-side session --------

        # @return [Hash] { session_id:, subject:, expires_at:, browser_cookies:,
        #                  server_side: { refresh_token: }, tokens: {...} }
        def complete(code:, returned_state:, cookie_state:, code_verifier:, subject:,
                     token_exchanger:, store:,
                     session_id: Pkce.token, clock: -> { Time.now.utc },
                     secure: true, same_site: Cookie::DEFAULT_SAME_SITE, ttl: DEFAULT_SESSION_TTL)
          verify_state!(returned_state: returned_state, cookie_state: cookie_state)
          raise InvalidHandshakeError, 'missing PKCE verifier' if blank?(code_verifier)
          raise InvalidHandshakeError, 'missing authorization code' if blank?(code)

          tokens = exchange!(token_exchanger) do
            token_exchanger.exchange_code(code: code, code_verifier: code_verifier)
          end

          record = store.load_subject(subject)
          raise SessionInvalidError, 'no such subject' if record.nil?

          revision = record.fetch(:credential_revision)
          now = clock.call.utc
          expires_at = (now + ttl).utc

          store.put_session(
            session_id: session_id, subject: subject,
            refresh_token: tokens.fetch(:refresh_token), credential_revision: revision,
            created_at: now, expires_at: expires_at
          )

          {
            session_id: session_id,
            subject: subject,
            expires_at: expires_at,
            browser_cookies: [
              Cookie.set(SESSION_COOKIE, session_id, max_age: ttl, secure: secure, same_site: same_site),
              Cookie.clear(VERIFIER_COOKIE, secure: secure, same_site: same_site),
              Cookie.clear(STATE_COOKIE, secure: secure, same_site: same_site)
            ],
            server_side: { refresh_token: tokens.fetch(:refresh_token) },
            tokens: { access_token: tokens[:access_token], expires_in: tokens[:expires_in].to_i }
          }
        end

        # --- 5: authenticate a presented session -------------------------------------

        # @return [Hash] { subject:, session_id: }
        # @raise [SessionInvalidError] unknown / expired / fenced.
        def authenticate(session_id:, store:, clock: -> { Time.now.utc })
          raise SessionInvalidError, 'no session presented' if blank?(session_id)

          session = store.load_session(session_id)
          raise SessionInvalidError, 'unknown session' if session.nil?

          now = clock.call.utc
          raise SessionInvalidError, 'session expired' if now >= to_time(session.fetch(:expires_at))

          subject = store.load_subject(session.fetch(:subject))
          raise SessionInvalidError, 'no such subject' if subject.nil?

          if session.fetch(:credential_revision) != subject.fetch(:credential_revision)
            raise SessionInvalidError, 'session revoked'
          end

          { subject: session.fetch(:subject), session_id: session_id }
        end

        # --- refresh the short-lived access token from the server-side refresh token --

        def refresh(session_id:, token_exchanger:, store:, clock: -> { Time.now.utc })
          resolved = authenticate(session_id: session_id, store: store, clock: clock)
          session = store.load_session(session_id)

          tokens = exchange!(token_exchanger) { token_exchanger.refresh(refresh_token: session.fetch(:refresh_token)) }

          {
            subject: resolved.fetch(:subject),
            tokens: { access_token: tokens[:access_token], expires_in: tokens[:expires_in].to_i }
          }
        end

        # --- sign out: delete this session AND fence every other one ------------------

        # Idempotent: a double sign-out still clears the cookie and is not an error.
        def revoke(session_id:, store:, secure: true, same_site: Cookie::DEFAULT_SAME_SITE)
          session = store.load_session(session_id) unless blank?(session_id)
          if session
            store.delete_session(session_id)
            store.bump_credential_revision(session.fetch(:subject))
          end

          { browser_cookies: [Cookie.clear(SESSION_COOKIE, secure: secure, same_site: same_site)] }
        end

        # --- URL guard (guarantee 4) --------------------------------------------------

        def assert_no_bearer_in_url!(url)
          query = url.to_s.split('?', 2)[1].to_s
          return url if query.empty?

          keys = query.split('&').map { |kv| kv.split('=', 2).first.to_s.downcase }
          offending = keys & BEARER_QUERY_KEYS
          return url if offending.empty?

          raise BearerInUrlError, "bearer credential must never appear in a URL: #{offending.join(', ')}"
        end

        # --- internals ----------------------------------------------------------------

        def verify_state!(returned_state:, cookie_state:)
          return if !blank?(returned_state) && !blank?(cookie_state) &&
                    Pkce.constant_time_equal?(returned_state, cookie_state)

          raise InvalidHandshakeError, 'oauth state mismatch'
        end

        def exchange!(_exchanger)
          yield
        rescue StandardError => e
          raise ExchangeError, "cognito token exchange failed: #{e.message}"
        end

        def encode_query(hash)
          hash.map { |k, v| "#{CGI.escape(k)}=#{CGI.escape(v.to_s)}" }.join('&')
        end

        def to_time(value)
          value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
        end

        def blank?(value)
          value.nil? || value.to_s.strip.empty?
        end
      end
    end
  end
end
