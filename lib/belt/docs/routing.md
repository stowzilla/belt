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

## See Also

- `belt explain controllers` — how controllers handle requests
- `belt explain deployment` — how routes become infrastructure
- `belt routes --help` — full CLI options
