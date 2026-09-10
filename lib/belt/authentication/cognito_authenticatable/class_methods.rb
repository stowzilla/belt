# frozen_string_literal: true

module Belt
  module Authentication
    module CognitoAuthenticatable
      # Class-side of cognito_authenticatable: the schema knobs the macro sets, and the
      # lookups that turn a token into a record.
      module ClassMethods
        attr_writer :cognito_roles, :cognito_default_role, :cognito_email_index

        # Allowed values for `role`. Set by the macro's `roles:` option.
        def cognito_roles
          @cognito_roles || ROLES
        end

        # Role given to a newly provisioned user.
        def cognito_default_role
          @cognito_default_role || DEFAULT_ROLE
        end

        # GSI used for email lookups, or false if the app doesn't need them.
        def cognito_email_index
          return @cognito_email_index if defined?(@cognito_email_index)

          DEFAULT_EMAIL_INDEX
        end

        def cognito_email_index_definition
          index = cognito_email_index
          return {} unless index

          { index.to_s => { partition_key: ATTRIBUTE_MAP['email'] } }
        end

        # Look up by Cognito sub. Returns nil rather than raising — callers are asking
        # whether the user exists yet, not asserting that they do.
        def for_sub(sub)
          id = sub.to_s
          return nil if id.empty?

          find(id)
        rescue ActiveItem::RecordNotFound
          nil
        end

        def for_email(email)
          normalized = normalize_cognito_email(email)
          return nil if normalized.empty?

          index = cognito_email_index
          index ? find_by(email: normalized, index: index.to_s) : find_by(email: normalized)
        end

        # Provision-or-refresh the row for the identity on this request.
        #
        # Called once per authenticated request, so it is deliberately write-averse: an
        # unchanged user costs one GetItem and no write. Only real drift (name changed
        # in Cognito, staff group granted or revoked, first sighting today) writes.
        #
        # @param sub [String] Cognito `sub` — becomes the primary key.
        # @param admin [Boolean] Whether the token carries a staff Cognito group.
        #   Cognito stays the source of truth, `role` only mirrors it, and passing
        #   false demotes — so removal from the group takes effect on the next request.
        # @return [self, nil] nil when there is no usable sub.
        def sync_from_claims!(sub:, email: nil, name: nil, admin: false, email_verified: false)
          id = sub.to_s
          return nil if id.empty?

          existing = for_sub(id)
          attrs = cognito_claim_attributes(
            email: email, name: name, admin: admin, email_verified: email_verified
          )

          user = existing ? refresh_from_cognito(existing, attrs) : provision_from_cognito(id, attrs)
          user&.after_cognito_sync
          user
        end

        def normalize_cognito_email(email)
          email.to_s.strip.downcase
        end

        private

        def cognito_claim_attributes(email:, name:, admin:, email_verified:)
          normalized_email = normalize_cognito_email(email)

          {
            email: normalized_email.empty? ? nil : normalized_email,
            name: cognito_display_name(name, normalized_email),
            role: admin ? ADMIN_ROLE : cognito_default_role,
            email_verified: Claims.truthy?(email_verified),
            last_seen_on: Time.now.utc.strftime('%Y-%m-%d')
          }.compact
        end

        # The `name` claim is optional — Cognito's hosted signup UI doesn't collect it
        # unless configured — so fall back to the email local part. Better than a blank
        # row in an admin screen.
        def cognito_display_name(name, normalized_email)
          given = name.to_s.strip
          return given unless given.empty?
          return nil if normalized_email.empty?

          normalized_email.split('@').first
        end

        def provision_from_cognito(id, attrs)
          create!(attrs.merge(id: id))
        rescue ActiveItem::RecordInvalid
          # Two concurrent first requests from the same new user: DynamoDB's
          # attribute_not_exists condition rejects the loser, surfacing as an
          # "already exists" validation error. The row we wanted now exists.
          for_sub(id)
        end

        # Write only what actually changed. `last_seen_on` is a date precisely so an
        # active session doesn't generate a write per request.
        def refresh_from_cognito(user, attrs)
          drift = attrs.reject { |attr, value| user.public_send(attr) == value }
          return user if drift.empty?

          user.update!(drift)
          user
        end
      end
    end
  end
end
