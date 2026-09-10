# frozen_string_literal: true

module Belt
  module Authentication
    module SessionCookie
      # The persistence contract the flow depends on, plus a process-local
      # implementation of it.
      #
      # SessionCookie::Flow never touches a database. It calls a `store` with the six
      # methods below, so an app backs sessions with whatever it already uses
      # (DynamoDB via ActiveItem, in practice) and tests pass this in-memory double.
      #
      # A conforming store implements:
      #
      #   put_session(session_id:, subject:, refresh_token:, credential_revision:,
      #               created_at:, expires_at:)   => void
      #   load_session(session_id)                => Hash | nil
      #       { subject:, refresh_token:, credential_revision:, expires_at: }
      #   delete_session(session_id)              => void
      #   load_subject(subject_id)                => Hash | nil  { credential_revision: }
      #   bump_credential_revision(subject_id)    => void  (fences every live session)
      #
      # "subject" is the Cognito sub / the app's user id — whatever the credential
      # revision is keyed by. The flow is agnostic to which.
      class MemoryStore
        def initialize
          @sessions = {}
          @subjects = Hash.new { |h, k| h[k] = { credential_revision: 0 } }
        end

        def put_session(session_id:, subject:, refresh_token:, credential_revision:,
                        created_at:, expires_at:)
          @sessions[session_id] = {
            subject: subject,
            refresh_token: refresh_token,
            credential_revision: credential_revision,
            created_at: created_at,
            expires_at: expires_at
          }
        end

        def load_session(session_id)
          @sessions[session_id]
        end

        def delete_session(session_id)
          @sessions.delete(session_id)
        end

        def load_subject(subject_id)
          @subjects.key?(subject_id) ? @subjects[subject_id] : nil
        end

        # Test/seed helper — an app's real store derives this from its user row.
        def register_subject(subject_id, credential_revision: 0)
          @subjects[subject_id] = { credential_revision: credential_revision }
        end

        def bump_credential_revision(subject_id)
          current = @subjects[subject_id][:credential_revision].to_i
          @subjects[subject_id] = { credential_revision: current + 1 }
        end
      end
    end
  end
end
