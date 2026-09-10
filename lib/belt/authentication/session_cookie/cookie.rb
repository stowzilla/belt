# frozen_string_literal: true

require 'cgi'

module Belt
  module Authentication
    module SessionCookie
      # Set-Cookie / Cookie plumbing for the session-cookie flow.
      #
      # Every cookie this emits is HttpOnly, Secure and SameSite, because that trio is
      # the whole point of the flow: HttpOnly keeps the credential out of
      # `document.cookie` (out of any JavaScript-readable browser storage), Secure keeps
      # it off plaintext HTTP, and SameSite scopes it to first-party requests.
      #
      # SameSite defaults to Lax so the top-level GET redirect back from the Cognito
      # Hosted UI still carries the cookie and sign-in can complete; Strict would drop it
      # on that hop and None would need a cross-site reason this flow does not have.
      module Cookie
        DEFAULT_SAME_SITE = 'Lax'
        DEFAULT_PATH = '/'

        module_function

        # Build a Set-Cookie header value.
        def set(name, value, max_age:, secure: true, same_site: DEFAULT_SAME_SITE,
                http_only: true, path: DEFAULT_PATH)
          parts = ["#{name}=#{CGI.escape(value.to_s)}"]
          parts << "Path=#{path}"
          parts << "Max-Age=#{max_age.to_i}"
          parts << "SameSite=#{same_site}"
          parts << 'Secure' if secure
          parts << 'HttpOnly' if http_only
          parts.join('; ')
        end

        # Expire a cookie now: same attributes, empty value, Max-Age 0.
        def clear(name, secure: true, same_site: DEFAULT_SAME_SITE, path: DEFAULT_PATH)
          parts = ["#{name}="]
          parts << "Path=#{path}"
          parts << 'Max-Age=0'
          parts << "SameSite=#{same_site}"
          parts << 'Secure' if secure
          parts << 'HttpOnly'
          parts.join('; ')
        end

        # Parse a raw Cookie request header into a name => value hash. Tolerates nil.
        def parse(cookie_header)
          return {} if cookie_header.nil? || cookie_header.to_s.strip.empty?

          cookie_header.split(/;\s*/).each_with_object({}) do |pair, acc|
            name, value = pair.split('=', 2)
            next if name.nil?

            acc[name.strip] = value.nil? ? '' : CGI.unescape(value)
          end
        end
      end
    end
  end
end
