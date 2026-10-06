# Testing

Belt ships an in-process **end-to-end harness** that drives the real router — no AWS, no
HTTP server, no browser. It's the tier between controller unit tests (which dispatch an
action directly and never touch routing) and full cloud e2e (which needs a deployed stack).

Load it opt-in — it is **not** required by `require 'belt'`, so it never ships in the
production Lambda path:

```ruby
require 'belt'
require 'belt/testing'
```

## What it exercises

The harness builds a synthetic API Gateway proxy event (method, path, body, and a
`requestContext` carrying Cognito-style claims) and routes it through the real
`Belt::ActionRouter` — exactly as API Gateway delivers it in production. The router finds
the route, extracts path params, resolves and instantiates the real controller, and runs
the real `before_action` chain. You assert on the HTTP-shaped response.

| Layer | In the harness |
|-------|----------------|
| Router, controllers, models, validations, authorization | **Real** |
| DynamoDB | Your choice (e.g. DynamoDB Local) — wired in your own test boot |
| Cognito | A claims hash in `requestContext.authorizer.claims` (the seam API Gateway's authorizer fills in production) |
| API Gateway | The synthetic event **is** the seam — the router is what APIGW dispatches to |

Anything genuinely external (Cognito token verification, Bedrock, Stripe, S3) stays a seam
you stub in your own boot file. Belt owns the generic request mechanics; your app owns its
data-store lifecycle and external stubs.

## The pieces

- **`Belt::Testing::E2E::Client`** — wraps one `Belt::ActionRouter`, builds synthetic
  events, dispatches, and returns a `Response`.
- **`Belt::Testing::E2E::Response`** — a parsed `{ status, headers, body, json }` struct
  with `ok?` and `[]` (reads a top-level key out of the parsed JSON body).
- **`Belt::Testing::E2E::Helpers`** — a mixin for `Minitest::Test` or RSpec example groups
  giving you `api_get` / `api_post` / `api_put` / `api_patch` / `api_delete` / `api_request`
  plus a `cognito_claims` builder.
- **`Belt::Testing::E2E.manifest_from_belt_routes(app_root:)`** — loads the route manifest
  via your app's own `belt routes -f json`, the same canonical path the deployed Lambda's
  manifest comes from, so the harness can't drift from Belt's route-building internals.

## Setup

Build the router once per process from your app's real manifest, then expose a client:

```ruby
require 'belt'
require 'belt/testing'

# ... boot your app: set test ENV, require 'belt', load models + controllers,
#     point Aws::DynamoDB::Client at DynamoDB Local, etc. ...

router = Belt::ActionRouter.new(
  routes:  Belt::Testing::E2E.manifest_from_belt_routes(app_root: APP_ROOT),
  gateway: 'api'
)
Belt::Testing::E2E.client = Belt::Testing::E2E::Client.new(router: router)
```

## Writing tests

```ruby
class ProjectsE2ETest < Minitest::Test
  include Belt::Testing::E2E::Helpers

  def test_lists_projects_for_an_admin
    res = api_get('/projects', claims: cognito_claims(groups: 'admins'))

    assert res.ok?                          # 2xx
    assert_equal 200, res.status
    assert_kind_of Array, res['projects']   # top-level key out of the JSON body
  end

  def test_creates_a_project
    res = api_post('/projects', body: { slug: 'alpha', name: 'Alpha' },
                                claims: cognito_claims(groups: 'admins'))

    assert_equal 201, res.status
    assert_equal 'alpha', res['project']['slug']

    # The write really happened — re-read it through the router.
    show = api_get('/projects/alpha', claims: cognito_claims(groups: 'admins'))
    assert show.ok?
  end

  def test_rejects_an_unauthenticated_request
    res = api_get('/projects')   # no claims → unauthenticated
    assert_equal 401, res.status
  end
end
```

### Request options

Every `api_*` helper (and `Client#request`) accepts:

| Option | Meaning |
|--------|---------|
| `body:` | request body as a **parsed Hash** (the LambdaHandler JSON-parses it in production) |
| `claims:` | Cognito claims hash injected into `requestContext.authorizer.claims`; omit for an unauthenticated request |
| `token:` | a Bearer token (e.g. an API key) set as the `Authorization` header, for non-Cognito auth |
| `headers:` | extra request headers |
| `query:` | query string parameters (`event['queryStringParameters']`) |

### Claims

`cognito_claims` builds the hash API Gateway's authorizer would inject:

```ruby
cognito_claims                                  # { 'sub' => 'e2e-user-sub', 'email' => '...' }
cognito_claims(sub: 'u-1', groups: 'admins')    # platform staff
cognito_claims(groups: %w[admins editors])      # array → space-joined 'cognito:groups'
cognito_claims(tenant: 't-1')                   # extra claims merge straight in
```

## Per-test client

By default the helpers use the process-wide `Belt::Testing::E2E.client`. To use a different
client (e.g. a second gateway), override `#e2e_client` in your test base class:

```ruby
class OpsE2ETest < Minitest::Test
  include Belt::Testing::E2E::Helpers

  def e2e_client
    @e2e_client ||= Belt::Testing::E2E::Client.new(router: OPS_ROUTER)
  end
end
```

## Keeping it out of the normal suite

The harness needs the **real** Belt stack (`require 'belt'`). If your unit suite shadows
`BeltController::Base` with a stub, keep the e2e tier in its own directory (e.g. `e2e/`,
not `spec/`) and run it as its own process so the two don't collide:

```bash
cd lambda
bundle exec ruby -Ie2e -e "Dir.glob('e2e/**/*_test.rb').each { |f| require File.expand_path(f) }"
```
