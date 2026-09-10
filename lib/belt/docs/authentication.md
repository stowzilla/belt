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

## See also

- `belt explain models` — ActiveItem
- `belt explain controllers` — `before_action`, response helpers
- `belt generate auth` — create the Cognito user pool
