# Routing

Belt routes map HTTP requests to controller actions. Routes are defined in
`config/routes.rb` using a Ruby DSL that mirrors infrastructure (API Gateway + Lambda).

## Defining Routes

```ruby
Belt.application.routes.draw do
  gateway :api do
    resources :posts
    resources :comments, only: [:index, :create]
    resource :profile, only: [:show, :update]
    get "health", action: :health
  end
end
```

## Route DSL Keywords

| Keyword | Purpose | Creates Lambda? |
|---------|---------|-----------------|
| `gateway` | Creates an API Gateway + default Lambda | Yes |
| `function` | Routes to a different Lambda (overrides gateway default) | Yes |
| `namespace` | Adds path prefix + controller module nesting | No |
| `scope` | Flexible path/module/auth grouping | No |

## How `resources` Maps to Verbs

`resources :posts` generates:

| Verb | Path | Action |
|------|------|--------|
| GET | /posts | index |
| POST | /posts | create |
| GET | /posts/{post_id} | show |
| PUT | /posts/{post_id} | update |
| DELETE | /posts/{post_id} | destroy |

**Note:** Belt uses PUT, not PATCH, for updates.

Use `only:` or `except:` to limit generated routes:

```ruby
resources :posts, only: [:index, :show, :create]
resources :comments, except: [:destroy]
```

## Singular Resources

`resource :profile` (no `:id` in the path):

| Verb | Path | Action |
|------|------|--------|
| GET | /profile | show |
| PUT | /profile | update |
| POST | /profile | create |
| DELETE | /profile | destroy |

## Nested Resource DSL

Inside a `resources` block, you can use Rails-like `member`, `collection`, `scope`,
`namespace`, and singular `resource` for DRYer route definitions:

```ruby
Belt.application.routes.draw do
  gateway :api do
    resources :projects do
      # Singular nested resource (no :id in path)
      resource :billing, only: [:show], tables: [:memberships]
      resource :token_usage, only: [:show]

      # Member routes (include /:id/)
      resources :webhooks do
        member do
          post :test            # → POST /projects/:project_id/webhooks/:webhook_id/test
        end
      end

      # Collection routes (no /:id/)
      resources :surfaces do
        collection do
          get :teams            # → GET /projects/:project_id/surfaces/teams
        end
        member do
          put :assign           # → PUT /projects/:project_id/surfaces/:surface_id/assign
        end
      end

      # Scope: groups routes with shared options
      scope path: 'billing', controller: :billing, tables: [:memberships] do
        get '/', action: :show  # → GET /projects/:project_id/billing
        post :checkout          # → POST /projects/:project_id/billing/checkout
        post :subscribe
        post :cancel
      end

      # Namespace: adds path prefix AND controller module
      namespace :admin do
        resources :users        # → /projects/:project_id/admin/users → admin/users controller
      end
    end
  end
end
```

### Action Inference

Symbol paths automatically become the action name:

```ruby
member do
  post :test                    # path: /test, action: :test
end
post 'mark-complete'            # path: /mark-complete, action: :mark_complete
```

Hyphens in path segments convert to underscores in action names.

### Controller Inheritance

Routes inside `member` and `collection` blocks inherit the parent resource's controller:

```ruby
resources :surfaces do
  member do
    put :assign                 # controller: surfaces, action: assign
  end
end
```

Override with the `controller:` option:

```ruby
member do
  get :billing, controller: :project_billing
end
```

### Namespace vs Scope

| Feature | `namespace` | `scope` |
|---------|-------------|---------|
| Path prefix | ✓ | Optional (`path:`) |
| Controller module | ✓ | Optional (`module:`) |
| Use case | Rails-like module nesting | Flexible grouping |

```ruby
# Namespace: path + controller module
namespace :admin do
  resources :users              # → /admin/users → admin/users controller
end

# Scope with path only (no controller change)
scope path: 'v2' do
  resources :users              # → /v2/users → users controller
end

# Scope with module only (no path change)
scope module: 'legacy' do
  resources :users              # → /users → legacy/users controller
end
```

## Namespace and Scope

```ruby
gateway :api do
  # Namespace: adds path prefix AND controller module
  namespace :admin do
    resources :users  # → /admin/users → Admin::UsersController
  end

  # Scope: flexible grouping without full nesting
  scope path: 'v2', module: 'legacy' do
    resources :widgets  # → /v2/widgets → Legacy::WidgetsController
  end
end
```

## Multiple Lambdas

Use `function` when routes should be handled by a separate Lambda:

```ruby
gateway :api do
  resources :posts        # → handled by "api" Lambda

  function :worker do
    resources :jobs       # → handled by "worker" Lambda
  end
end
```

## Authentication

```ruby
gateway :api, auth: :cognito do
  resources :posts                    # requires cognito auth
  get "health", action: :health, auth: :none  # public
end
```

## Table Access

Declare which DynamoDB tables a route accesses (used by Terraform for IAM):

```ruby
resources :posts, tables: [:posts, :comments]
```

## Throttling

Cap how many requests API Gateway lets through to a route with `throttle:`:
`rate` is the steady requests per second, `burst` is how many it absorbs at once.
Over the limit, callers get a `429` before the Lambda runs.

```ruby
gateway :api, auth: :none, throttle: { rate: 50, burst: 100 } do  # default for every route
  post "/reports", to: "reports#create", throttle: { rate: 5, burst: 10 }
  get "/health", to: "health#show", throttle: false             # opt out of the default

  scope path: "family", throttle: { rate: 1, burst: 2 } do       # scope, namespace, function
    resources :devices, only: [:create]                         # and nested resources inherit
  end
end
```

A route's own `throttle:` wins, then the nearest enclosing `scope` / `namespace` /
`function` / `resources` block, then the gateway's. `throttle: false` means "no
route-level throttle". `belt routes -f json` puts the result on each route, and the
conveyor-belt provider (0.0.20+) applies it as API Gateway stage method settings.

Where routes.rb sets no throttle, the provider falls back to the serving Lambda's
`throttle:` in `config/lambda/<fn>.yml`, then to the provider's stage-level
`throttle` block. Note that a **gateway-level default in routes.rb is a route-level
throttle**: it beats both of those. Use `throttle: false` on a route if the Lambda
YAML should decide it.

**Throttles are per route, not per caller.** API Gateway keeps one bucket per
route, shared by everyone. `throttle: { rate: 5, burst: 10 }` on `POST /reports`
stops a script from running up the bill, but that same script also uses up the
limit for real players. For per-caller limits (what Rails' controller
`rate_limit to:, within:` gives you), put a WAF rate-based rule in front of the
gateway (see below).

Throttling is approximate, so expect a few requests either side of the limit.
Method settings override the stage's `*/*` setting. Anything that throttles "the
whole stage" by patching only `*/*` (an emergency kill switch, for example) no
longer covers routes that have their own `throttle`. It has to patch those
method settings too, or cut Lambda concurrency instead.

### Per-caller limits: WAF rate rule recipe

WAF counts requests per client IP over a window and blocks an IP that goes over.
Attach a REGIONAL web ACL to the gateway stage with the provider's
`waf_web_acl_arn`. WAF bills per web ACL, per rule and per million requests,
so one ACL with a few rules is the usual shape.

```hcl
# infrastructure/modules/app/waf.tf
resource "aws_wafv2_web_acl" "api" {
  name  = "${var.app_name}-${var.environment}-api"
  scope = "REGIONAL" # API Gateway stage; CLOUDFRONT scope is only for distributions (us-east-1)

  default_action {
    allow {}
  }

  # 20 POST /reports per IP per minute
  rule {
    name     = "reports-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = 20  # requests per window, minimum 10
        evaluation_window_sec = 60  # 60, 120, 300 or 600
        aggregate_key_type    = "IP"

        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                search_string         = "/reports"
                positional_constraint = "ENDS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "POST"
                positional_constraint = "EXACTLY"
                field_to_match {
                  method {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "reports-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.app_name}-${var.environment}-api"
    sampled_requests_enabled   = true
  }
}
```

```hcl
resource "conveyor_belt" "main" {
  # ...
  waf_web_acl_arn = aws_wafv2_web_acl.api.arn
}
```

- **Scope the rule down** to the routes that cost money (public writes). An
  unscoped rule counts every request, including page loads and polling.
- **Key on `IP`** when clients call the gateway directly. Only if a CloudFront
  distribution you control sits in front of the API, use
  `aggregate_key_type = "FORWARDED_IP"` with a
  `forwarded_ip_config { header_name = "X-Forwarded-For", fallback_behavior = "MATCH" }`.
  Otherwise every request counts against CloudFront's handful of edge IPs. Without
  CloudFront in front, clients can set `X-Forwarded-For` to anything, so don't
  trust it.
- **Watch the path WAF sees.** On the `execute-api` URL the path starts with the
  stage name (`/dev/reports`), and on a custom domain it doesn't. `ENDS_WITH` matches
  both.
- Try a new rule with `action { count {} }` first, check the CloudWatch metric, then
  switch to `block {}`.
- Keep the route `throttle:` as well. WAF stops one noisy IP, and the throttle caps
  the total when many IPs push at once.

## Inspecting Routes

```bash
belt routes                    # display all routes
belt routes -g posts           # filter by pattern
belt routes -f json            # machine-readable output
belt routes --namespace api    # generate Ruby route manifest
```

## Runtime Routing

The Lambda entry point uses `Belt::ActionRouter` with the generated route manifest:

```ruby
require "belt"
include Belt::LambdaHandler

ROUTER = Belt::ActionRouter.new(routes: Routes::API, gateway: "api")

def execute(path:, body:, event:)
  ROUTER.route(event: event, body: body)
end
```

The router matches the incoming HTTP method + path against the manifest and
dispatches to the appropriate controller and action.

## See Also

- `belt explain controllers` — how controllers handle requests
- `belt explain deployment` — how routes become infrastructure
- `belt routes --help` — full CLI options
