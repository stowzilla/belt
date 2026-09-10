# frozen_string_literal: true

require_relative 'session_cookie/pkce'
require_relative 'session_cookie/cookie'
require_relative 'session_cookie/memory_store'
require_relative 'session_cookie/flow'

module Belt
  module Authentication
    # Session-cookie sign-in for Belt apps: authorization code + PKCE, refresh held
    # server-side, an opaque session id in an HttpOnly/Secure/SameSite cookie, and
    # revocation by credential-revision fencing.
    #
    # This is the opt-in alternative to holding a Cognito token in the browser. Where
    # `cognito_authenticatable` reads a bearer ID token off the request (fine for
    # machine callers and gateway-authorized routes), SessionCookie keeps every bearer
    # credential off the client entirely — nothing in localStorage, nothing in a URL.
    #
    # Generate it with `belt generate auth --session-cookie`. See
    # `belt explain authentication` and SessionCookie::Flow for the flow itself.
    module SessionCookie
    end
  end
end
