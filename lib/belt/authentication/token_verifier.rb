# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module Belt
  module Authentication
    # Verifies a Cognito ID token taken from an `Authorization: Bearer` header.
    #
    # A route with an API Gateway authorizer never needs this: the gateway checked the
    # token and handed over the claims. A route without one has nothing in front of it,
    # so a token there counts only if it was signed by the app's own pool, for one of
    # the app's own clients. Everything is required — signature (RS256, key looked up
    # by `kid` in the pool's JWKS), `exp`, `iss`, `token_use == 'id'` and `aud`.
    #
    # The key set is fetched once per Lambda container. An unknown `kid` triggers a
    # refetch (Cognito rotates rarely), but at most once per REFETCH_INTERVAL, so a
    # caller inventing key ids cannot make every request pay for an outbound call.
    module TokenVerifier
      ALGORITHM = 'RS256'
      JWKS_TIMEOUT = 2
      # Seconds before an unknown `kid` may trigger another fetch of a key set we hold.
      REFETCH_INTERVAL = 60
      # Seconds before retrying a fetch that failed outright.
      RETRY_INTERVAL = 5

      @key_sets = {}
      @mutex = Mutex.new

      class << self
        # The verified claims, or nil. Never raises: a token that can't be verified
        # means "no identity". Nil too when the issuer or client ids are unknown —
        # without them there is nothing to verify against.
        def verify(token, issuer:, client_ids:)
          audiences = Array(client_ids).map(&:to_s).reject(&:empty?)
          return nil if token.to_s.empty? || issuer.to_s.empty? || audiences.empty?

          segments = token.to_s.split('.')
          return nil unless segments.length == 3
          return nil unless signed_by_pool?(segments, issuer)

          claims = JSON.parse(decode_segment(segments[1]))
          valid_claims?(claims, issuer, audiences) ? claims : nil
        rescue StandardError
          nil
        end

        # Test seam: supply a pool's keys ({ kid => OpenSSL::PKey::RSA }) so nothing
        # is fetched.
        def store_keys(issuer, keys)
          @mutex.synchronize { @key_sets[issuer] = { keys: keys, fetch_after: monotonic_now + REFETCH_INTERVAL } }
        end

        def reset!
          @mutex.synchronize { @key_sets = {} }
        end

        private

        def signed_by_pool?(segments, issuer)
          header = JSON.parse(decode_segment(segments[0]))
          return false unless header.is_a?(Hash) && header['alg'] == ALGORITHM

          key = key_for(header['kid'], issuer)
          return false unless key

          key.verify('SHA256', decode_segment(segments[2]), "#{segments[0]}.#{segments[1]}")
        end

        def valid_claims?(claims, issuer, audiences)
          return false unless claims.is_a?(Hash)
          return false unless claims['exp'].is_a?(Numeric) && claims['exp'] > Time.now.to_i
          return false unless claims['iss'] == issuer
          return false unless claims['token_use'] == 'id'

          audiences.intersect?(Array(claims['aud']).map(&:to_s))
        end

        def key_for(kid, issuer)
          return nil if kid.to_s.empty?

          @mutex.synchronize do
            set = @key_sets[issuer]
            set = @key_sets[issuer] = fetch_key_set(issuer) if refetch?(set, kid)
            set[:keys][kid]
          end
        end

        def refetch?(set, kid)
          return true if set.nil?

          !set[:keys].key?(kid) && monotonic_now >= set[:fetch_after]
        end

        def fetch_key_set(issuer)
          keys = fetch_keys(issuer)
          { keys: keys || {}, fetch_after: monotonic_now + (keys ? REFETCH_INTERVAL : RETRY_INTERVAL) }
        end

        # The JWKS URL comes from the configured issuer, never from the token.
        # Returns nil when the key set could not be fetched.
        def fetch_keys(issuer)
          uri = URI("#{issuer}/.well-known/jwks.json")
          options = { use_ssl: uri.scheme == 'https', open_timeout: JWKS_TIMEOUT, read_timeout: JWKS_TIMEOUT }
          response = Net::HTTP.start(uri.host, uri.port, **options) { |http| http.get(uri.request_uri) }
          return nil unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body).fetch('keys', []).each_with_object({}) do |jwk, keys|
            keys[jwk['kid']] = rsa_key(jwk) if jwk['kty'] == 'RSA'
          end
        rescue StandardError
          nil
        end

        # OpenSSL 3 keys are immutable, so build the PKCS#1 DER instead of setting n/e.
        def rsa_key(jwk)
          modulus = OpenSSL::BN.new(decode_segment(jwk['n']), 2)
          exponent = OpenSSL::BN.new(decode_segment(jwk['e']), 2)
          der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(modulus), OpenSSL::ASN1::Integer(exponent)]).to_der
          OpenSSL::PKey::RSA.new(der)
        end

        def decode_segment(segment)
          Base64.urlsafe_decode64(segment + ('=' * ((4 - (segment.length % 4)) % 4)))
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
