# Belt routing DSL

Routes live in `infrastructure/routes.tf.rb` and are read both by the
**conveyor-belt** Terraform provider (for infra) and by `belt routes` (which
generates the runtime route constants at `lambda/lib/routes/<namespace>_routes.rb`).

Run `belt explain routing` for the canonical docs.

## Four keywords

| Keyword | Purpose | Changes which Lambda? |
|---|---|---|
| `gateway` | API Gateway + default Lambda | **Yes** — sets default for routes inside |
| `function` | Route to a different Lambda | **Yes** — overrides gateway default |
| `namespace` | Path prefix + controller module | No — code organization only |
| `scope` | Path/module/auth grouping | No — grouping + shared options |

**Critical:** `namespace` and `scope` are purely organizational. Only `gateway`
and `function` determine the serving Lambda.

```ruby
Belt.application.routes.draw do
  gateway :api, auth: :cognito do
    resources :posts                    # lambda: api, /posts, posts controller

    namespace :admin do
      resources :users                  # /admin/users, admin/users controller
    end

    function :worker do
      resources :jobs                   # lambda: worker, /jobs, jobs controller
    end

    scope path: 'v2', module: 'legacy' do
      resources :widgets                # /v2/widgets, legacy/widgets controller
    end
  end
end
```

## Nested resources

```ruby
resources :projects do
  resource  :billing, only: [:show], tables: [:memberships]  # singular, no :id

  resources :webhooks do
    member     { post :test }      # POST /projects/:project_id/webhooks/:webhook_id/test
  end

  resources :surfaces do
    collection { get :teams }      # GET /projects/:project_id/surfaces/teams
    member     { put :assign }     # PUT /projects/:project_id/surfaces/:surface_id/assign
  end

  scope path: 'billing', controller: :billing, tables: [:memberships] do
    get  '/', action: :show
    post :checkout
  end
end
```

- **Action inference:** `post :checkout` uses `checkout` as both path segment and action.
- **Controller inheritance:** `member`/`collection` inherit the parent resource's controller.
- **`tables:`** declares DynamoDB access for IAM generation.

## Request/response model inference (for `belt routes` / contracts)

Resolution order (highest first):

1. **Explicit per-route:** `put "/items/:id", request_model: :update_item`
2. **Hash per-action:** `resources :items, request_model: { create: :create_item }`
3. **Convention cascade** (POST/PUT/PATCH only):
   - `:<verb>_<gateway>_<singular>` → e.g. `:create_customer_item`
   - `:<verb>_<singular>` → e.g. `:create_item`

**Response model:** singular of the resource name → `resources :items` looks for
`model :item` in `contracts.rb`. Applies to all verbs. No match = no model documented.
