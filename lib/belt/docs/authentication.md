# Authentication

Cognito owns authentication — passwords, MFA, hosted signup, groups. Belt owns the
**record** of the human Cognito authenticated, so your app can answer its own questions
about that person without re-reading JWT claims in every controller.

Declare it on a model and you're done:

```ruby
class User < ApplicationRecord
  cognito_authenticatable
end
```

That one line supplies:

| | |
|---|---|
| Primary key | the Cognito `sub` — resolving the caller is one `GetItem` |
| Attributes | `email`, `name`, `role`, `email_verified`, `last_seen_on` |
| GSI | `EmailIndex`, for finding a person by address |
| Class methods | `.sync_from_claims!`, `.for_sub`, `.for_email` |
| Instance methods | `#admin?`, `#email_verified?` |

Controllers get `current_user`, `authenticate_user!`, `user_signed_in?`, and
`cognito_admin?` with no `include` and no configuration.

## The table

```hcl
resource "aws_dynamodb_table" "users" {
  name         = "${var.app_name}-${var.environment}-users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id" # the Cognito sub

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "email"
    type = "S"
  }

  global_secondary_index {
    name            = "EmailIndex"
    hash_key        = "email"
    projection_type = "ALL"
  }
}
```

Identity attributes are stored snake_case (`email_verified`, not `emailVerified`) so
they read the same in the console, in `dynamodb.tf`, and in a GSI key definition.

Grant the table to every Lambda, not per route. Authenticated requests read it *before*
the action runs, so per-route `tables:` means listing it on every route and 500ing on
whichever one you missed.

## In a controller

```ruby
class ProfilesController < ApplicationController
  before_action :authenticate_user!

  def show
    @profile = current_user
  end
end
```

`authenticate_user!` raises `Belt::Authentication::NotAuthenticated`, which Belt already
maps to **401**. It has to raise: `before_action` cannot halt the chain by returning a
response — return values are discarded and the action runs anyway.

| Method | |
|---|---|
| `current_user` | the user record, or nil. Memoized per request |
| `user_signed_in?` | is there a Cognito identity on this request? |
| `authenticate_user!` | `before_action` guard → 401 |
| `cognito_admin?` | does the token carry a staff Cognito group? |
| `cognito_claims` | raw claims, if you really need them |
| `bearer_token` | the raw `Authorization: Bearer` credential |

If your app has a *second* credential scheme — an API key for machine callers, say —
override `skip_cognito_identity?` to declare that such a request is not a human:

```ruby
def skip_cognito_identity?
  agent_request?   # `Authorization: Bearer fp_...`
end
```

Usually unnecessary: a credential that isn't a Cognito ID token yields no claims and
therefore no `current_user`. It matters when a request could be read as both.

## Just-in-time provisioning

There is no signup endpoint to keep in step with Cognito's hosted UI. The first
authenticated request from a user writes the row; later requests only write when
something actually drifted — a name changed in Cognito, a staff group was granted or
revoked, or it's the first sighting today. Steady state is one `GetItem` and no write.

`last_seen_on` is a **date**, not a timestamp, precisely so an active session doesn't
generate a write per request.

To hang your own behaviour off that moment, override the hook:

```ruby
class User < ApplicationRecord
  cognito_authenticatable

  # Runs whenever an identity is resolved from a token.
  def after_cognito_sync
    claim_pending_invitations!
  end
end
```

## Platform staff

`role` is platform-wide: `member` or `admin`. It mirrors a Cognito group on **every**
request, so removing someone from the group locks them out on their very next call.

```ruby
current_user.admin?   # FeatureParity staff — can see across tenants
cognito_admin?        # the grant: does this token carry the group?
```

Per-tenant roles (owner of a project, member of an org) are your domain, not this
concern's. Model them yourself.

Grant staff by hand — Terraform should create the group but not manage its members, so
that a `terraform apply` can't hand out platform-wide read access:

```bash
aws cognito-idp admin-add-user-to-group \
  --user-pool-id <pool> --username <you> --group-name admins
```

## Configuration

Every setting has a working default. An app whose model is `User` and whose staff group
is `admins` configures nothing.

```ruby
# lambda/config/environment.rb
Belt.configure do |config|
  config.authentication.user_class   = 'Account'  # default: 'User'
  config.authentication.admin_groups = %w[staff]  # default: ['admins'], or ADMIN_COGNITO_GROUPS
  config.authentication.issuer       = '...'      # default: derived from COGNITO_USER_POOL_ID
end
```

Macro options:

```ruby
cognito_authenticatable roles: %w[member admin support],
                        default_role: 'member',
                        email_index: 'PeopleEmailIndex' # or false to skip it
```

## Two token shapes

A route can be authenticated either way, and both are handled:

1. **API Gateway Cognito authorizer** — claims arrive pre-verified under
   `requestContext.authorizer.claims`, with every value flattened to a string
   (`"true"`, `"[admins, members]"`).
2. **A raw `Authorization: Bearer <id token>` header** — the Lambda decodes it.

Case 2 is signature-unverified by design: where an authorizer is attached, the gateway
already checked the signature and an unsigned token never reaches your code. What can
still be checked cheaply is checked — structure, expiry, issuer, and `token_use` (an
access token is rejected; it carries no email or name).

Anything that isn't a Cognito ID token — including your own API key scheme sharing the
same header — reads as "no Cognito identity" rather than an error, so
`current_user` is simply nil.

## Session-cookie sign-in (PKCE, no token in the browser)

The default flow above expects a bearer ID token on the request. That is right for
machine callers and gateway-authorized routes, but a browser SPA holding a Cognito
token — in `localStorage`, in a URL — is exactly the exposure a lot of security
requirements are written to forbid.

`belt generate auth --session-cookie` produces the alternative: **authorization code
flow with PKCE**, the **refresh token held server-side**, and only an **opaque session
id in a `Secure` `HttpOnly` `SameSite` cookie** reaching the client. No bearer
credential is ever in a URL or in browser storage.

What it generates on top of the usual `belt g auth` output:

| File | Role |
|---|---|
| `infrastructure/modules/app/cognito.tf` | Public client (no secret), Hosted-UI domain, `allowed_oauth_flows = ["code"]`, callback/logout URLs |
| `infrastructure/modules/app/cognito_session_variables.tf` | `cognito_callback_urls`, `cognito_logout_urls` |
| `lambda/models/session.rb` | Server-side session record — holds the refresh token |
| `lambda/lib/session_store.rb` | Persistence adapter for the flow |
| `lambda/controllers/…/sessions_controller.rb` | `sign_in` / `callback` / `sign_out` endpoints |

The runtime lives in the gem, under `Belt::Authentication::SessionCookie`:

```ruby
Flow = Belt::Authentication::SessionCookie::Flow

# GET /auth/sign_in — redirect to the Hosted UI, set PKCE + state cookies
begun = Flow.begin(hosted_ui_domain:, client_id:, redirect_uri:)
redirect_to begun[:authorize_url], cookies: begun[:cookies]

# GET /auth/callback — exchange the code, establish a server-side session
result = Flow.complete(code:, returned_state:, cookie_state:, code_verifier:,
                       subject:, token_exchanger:, store:)
redirect_to '/', cookies: result[:browser_cookies]
# result[:server_side][:refresh_token] stays on the server — never a cookie

# POST /auth/sign_out — delete this session AND fence every other one
Flow.revoke(session_id:, store:)
```

The five guarantees are enforced in `Flow`, not left to the caller:

1. **PKCE** — the authorize URL carries the S256 *challenge*; the exchange carries the
   *verifier* (an `HttpOnly` cookie). A stolen code can't be exchanged without it.
2. **Refresh server-side** — returned only under `:server_side`, physically apart from
   `:browser_cookies`.
3. **Secure/HttpOnly/SameSite** — on every cookie the flow emits.
4. **No bearer in a URL** — `Flow.assert_no_bearer_in_url!` guards every URL built.
5. **Expiry + revocation** — a session is bound to the subject's `credential_revision`;
   `authenticate` refuses an expired or fenced session, and `revoke` bumps the revision
   so signing out one place fences everywhere on the next read.

The `store` seam (see `SessionCookie::MemoryStore` for the contract) and the
`token_exchanger` seam keep the flow free of AWS and network in tests.

## See also

- `belt explain models` — ActiveItem
- `belt explain controllers` — `before_action`, response helpers
- `belt generate auth` — create the Cognito user pool
- `belt generate auth --session-cookie` — PKCE + server-side refresh + cookie session
