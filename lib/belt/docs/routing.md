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

## WebSocket Gateways

WebSocket routes use a separate gateway type and the `on` keyword:

```ruby
gateway :live, type: :websocket do
  on :connect,    to: 'live_events#connect',    tables: [:live_connections]
  on :disconnect, to: 'live_events#disconnect', tables: [:live_connections]
  on :subscribe,  to: 'live_events#subscribe',  tables: [:live_connections]
end
```

The lifecycle names become `$connect`, `$disconnect`, and `$default`. Custom
route keys are matched exactly against API Gateway's `requestContext.routeKey`.
Do not mix HTTP and WebSocket routes in one gateway.

WebSocket entries appear under `websocket_routes` in JSON output so REST-only
conveyor-belt releases ignore them safely. Use the `belt-live` plugin to install
the API Gateway v2 infrastructure, connection store, publisher, and client helper.
See `belt explain realtime`.

## See Also

- `belt explain controllers` — how controllers handle requests
- `belt explain realtime` — WebSocket push transport
- `belt explain deployment` — how routes become infrastructure
- `belt routes --help` — full CLI options
