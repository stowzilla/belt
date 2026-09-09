# frozen_string_literal: true

require 'json'
require 'base64'

module Belt
  module Authentication
    # Reads Cognito claims off a Lambda event.
    #
    # Two shapes have to be handled, because a route can be authenticated either way:
    #
    #   1. API Gateway Cognito authorizer — claims arrive pre-verified under
    #      requestContext.authorizer.claims, with every value flattened to a String.
    #   2. A raw `Authorization: Bearer <id token>` header — the Lambda decodes it.
    #
    # Case 2 is signature-unverified by design: when a Cognito authorizer is attached,
    # the gateway has already checked the signature and an unsigned token never reaches
    # us. What we can still check cheaply is checked (structure, expiry, issuer, token
    # use), which is what stops an expired or foreign token from being waved through on
    # routes that read the header directly.
    module Claims
      # Cognito sends `cognito:groups` as a JSON array in the raw token, but API
      # Gateway flattens it to a string — "[admins, members]" or "admins,members".
      GROUPS_CLAIM = 'cognito:groups'

      TRUTHY = [true, 'true', 1, '1'].freeze

      class << self
        # Claims for this request, or nil if there is no usable Cognito identity.
        def from_event(event, issuer: nil)
          authorizer = event.dig('requestContext', 'authorizer', 'claims')
          return authorizer if authorizer

          token = bearer_token(event)
          return nil unless token

          decode(token, issuer: issuer)
        end

        # The raw Bearer credential, whatever it is. Callers that only want Cognito
        # tokens rely on #decode rejecting anything that isn't one — an app's own API
        # key scheme can share the header without special-casing here.
        def bearer_token(event)
          header = authorization_header(event)
          return nil unless header&.start_with?('Bearer ')

          token = header.sub('Bearer ', '').strip
          token.empty? ? nil : token
        end

        def authorization_header(event)
          headers = event['headers'] || {}
          headers['Authorization'] || headers['authorization']
        end

        # Decode a Cognito ID token's payload, rejecting it unless it is one.
        # Returns nil rather than raising: a bad token means "no identity", and every
        # caller here is deciding whether an identity exists.
        def decode(token, issuer: nil)
          payload = payload_segment(token)
          return nil unless payload

          claims = JSON.parse(payload)
          return nil unless claims.is_a?(Hash)
          return nil if expired?(claims)
          return nil unless issuer_matches?(claims, issuer)
          return nil unless id_token?(claims)

          claims
        rescue ArgumentError, JSON::ParserError
          nil
        end

        def groups(claims)
          parse_groups(claims && claims[GROUPS_CLAIM])
        end

        def parse_groups(raw)
          return [] if raw.nil?
          return raw.map(&:to_s) if raw.is_a?(Array)

          raw.to_s.delete('[]').split(',').map(&:strip).reject(&:empty?)
        end

        # Booleans arrive as JSON booleans from a decoded token and as strings from
        # API Gateway authorizer claims.
        def truthy?(value)
          TRUTHY.include?(value)
        end

        private

        def payload_segment(token)
          parts = token.to_s.split('.')
          return nil unless parts.length == 3

          segment = parts[1]
          segment += '=' * (4 - (segment.length % 4)) if (segment.length % 4) != 0
          Base64.urlsafe_decode64(segment)
        end

        def expired?(claims)
          exp = claims['exp']
          !exp.nil? && Time.now.to_i > exp.to_i
        end

        def issuer_matches?(claims, issuer)
          return true if issuer.nil?

          claims['iss'] == issuer
        end

        # Belt authenticates with ID tokens; an access token carries no email/name and
        # must not stand in for one.
        def id_token?(claims)
          use = claims['token_use']
          use.nil? || use == 'id'
        end
      end
    end
  end
end
