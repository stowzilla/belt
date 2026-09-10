# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'base64'

module Belt
  module Authentication
    module SessionCookie
      # PKCE primitives (RFC 7636). The admin SPA is a public client with no secret, so
      # the authorization-code exchange is secured by proving possession of a verifier
      # whose hash was committed up front:
      #
      #   * the authorize URL carries the S256 *challenge* (a hash — safe to expose),
      #   * the token exchange carries the *verifier* (secret — lives only in an
      #     HttpOnly cookie),
      #
      # so a code intercepted from the redirect cannot be exchanged without the verifier.
      module Pkce
        module_function

        # A high-entropy code verifier: 43-128 unreserved chars. urlsafe_base64(64)
        # without padding lands in range and uses the allowed alphabet.
        def verifier
          SecureRandom.urlsafe_base64(64).tr('=', '')
        end

        # S256 challenge: BASE64URL(SHA256(verifier)), unpadded (RFC 7636 4.2).
        def challenge(verifier)
          digest = Digest::SHA256.digest(verifier.to_s)
          Base64.urlsafe_encode64(digest).tr('=', '')
        end

        # Whether a verifier hashes to a challenge. Used by a fake token exchanger in
        # tests to model exactly what Cognito enforces.
        def matches?(verifier:, challenge:)
          v = verifier.to_s
          c = challenge.to_s
          return false if v.empty? || c.empty?

          constant_time_equal?(challenge(v), c)
        end

        # A CSRF state / opaque id token. urlsafe_base64 so it is cookie- and URL-safe.
        def token(bytes = 32)
          SecureRandom.urlsafe_base64(bytes)
        end

        def constant_time_equal?(left, right)
          a = left.to_s
          b = right.to_s
          return false unless a.bytesize == b.bytesize

          res = 0
          a.bytes.zip(b.bytes) { |x, y| res |= x ^ y }
          res.zero?
        end
      end
    end
  end
end
