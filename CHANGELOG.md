# Changelog

## Unreleased

### Contributing & plugins

- README: **Plugins** and **Contributing** sections — how to contribute to belt, how plugins register via `GeneratorRegistry`, layout used by `belt-messaging` / `belt-pay`, generator checklist for humans and agents.
- **`belt plugin new <name>`** — scaffold a new plugin gem (gemspec, `Belt::<Name>` module, generator stub, RSpec, README), similar to `rails plugin new`.

## 0.2.10

### Quiet `belt new` (with optional verbose)

`belt new` prints a short phase summary by default (skeleton, environments, frontend,
bundle, state bucket) instead of every path plus AWS/npm noise.

Use `-v` / `--verbose` for Rails-style per-file `create` lines when you want the
inventory. Nested generators skip their own next-steps banners; the final success
block still owns next steps. State-bucket setup stays non-interactive either way.

### State bucket naming (global uniqueness)

S3 bucket names are a **global** namespace across all AWS accounts. The previous default
`belt-terraform-state` only works for the first account that creates it — everyone else
hits "owned by a different AWS account".

**Fix:** shared bucket is still one-per-account (all apps share it), but the name is now:

```
belt-terraform-state-<account_id>
```

- Still one bucket for all belt apps in an account (state key: `<app>/<env>/terraform.tfstate`)
- `--bucket` still overrides when you want a custom name
- `belt setup state` rewrites `backend.tf` with the resolved name
- Existing installs that already own `belt-terraform-state` can keep using `--bucket belt-terraform-state`

### Implicit responses (Rails-style assigns)

Controllers can set instance variables and skip the explicit `success_response` call:

```ruby
def index
  @posts = Post.all
end

def show
  @post = Post.find(params[:id])
end
```

Belt auto-builds `success_response({ posts: [...] })` / `{ post: {...} }` from assigns set
during the action. Serialization:

- Models → `to_h` (ActiveItem already defines this)
- `ActiveItem::Relation` / Enumerable → map each record via `to_h`
- Nested hashes/arrays recurse

Explicit `success_response` / `error_response` / `html_response` / `render` / `head` still win
when returned. Rescue handlers still use `error_response`.

### Default format (`:json` / `:html`)

```ruby
# App-wide (lambda/config/environment.rb)
Belt.configure do |c|
  c.default_format = :json   # default — API first
end

# Per-controller override (inherits down the chain)
class PagesController < ApplicationController
  self.default_format = :html
end
```

| `default_format` | Implicit response (no explicit helper) |
|---|---|
| `:json` (default) | `success_response` from assigns |
| `:html` | `render` template `views/<controller>/<action>.html.erb` (missing → `TemplateNotFound`) |

### Symbol status codes, `head`, `response_status`

```ruby
success_response({ post: post.to_h }, :created)   # 201
error_response("Nope", :unprocessable_entity)     # 422
head :no_content                                  # 204 empty body
head :created                                     # 201 empty body

def create
  @post = Post.create!(...)
  response_status :created   # 201 + implicit assigns body
end
```

Bare integers still work. Symbols match the Rack/Rails names (`:created`, `:not_found`, …).

## 0.3.0

### Pre-Deploy Backups

Belt now runs automated backups before each deploy when configured. No standalone scripts or generators — `belt deploy` owns the entire lifecycle.

**New: Backup Config DSL** — configure backups per environment in `infrastructure/<env>/belt.rb`:

```ruby
Belt.configure do |config|
  config.backups do
    dynamodb :all                    # PITR + on-demand snapshot before deploy
    cognito :users, :pool_config    # Export users + pool config to backup bucket
    s3 :legal_documents             # Sync bucket to backup bucket
    retention snapshots: 90, cognito: 10, s3: 10
  end
end
```

Simple mode: `config.backups = true` enables DynamoDB backups for all tables.

**Backup types supported:**
- **DynamoDB**: Verifies PITR is enabled, creates on-demand snapshots (retained per policy)
- **Cognito**: Paginated user export + pool configuration → versioned backup bucket
- **S3**: Syncs configured buckets to a dedicated backup bucket

**Deploy lifecycle (updated):**
1. Validate
2. Generate route manifests
3. **Run backups** (if configured for this environment)
4. `terraform init`
5. `terraform plan`
6. Confirm apply
7. `terraform apply`

**New CLI flags:**
- `belt deploy prod --skip-backup` — skip backup phase (CI re-runs, etc.)
- `belt deploy prod --backup-only` — run backups without deploying

**TablesCommand** — all generated DynamoDB tables now include PITR and deletion protection by default:

```hcl
point_in_time_recovery {
  enabled = var.enable_pitr  # true by default
}
deletion_protection_enabled = var.deletion_protection  # true in prod, false in dev
```

## 0.2.5

### Table Generation Separation

- Separated table generation from API schema contracts

### Schema DSL

- Added index support to schema DSL for custom GSIs

## 0.1.13

### Generator Extension API

- Gems can now register generators by placing a file at `lib/belt/generators/<name>_generator.rb`.
- Discovered automatically via `Gem.loaded_specs` — no manual registration needed.
- Available as `belt generate <name>` / `belt destroy <name>`.
- Generator contract: `.run(args)` (required), `.destroy(args)` (optional), `.description` (optional).
- Help output includes gem-provided generators under "Gem Generators" section.

## Unreleased

## 0.1.11

### Route DSL

- `resources` / `resource` honor `scope path:` (and nested path scopes).  
  Example: `scope path: "admin", auth: :cognito { resources :users }` → `/admin/users…` with Cognito auth.
- Nested `scope path:` segments stack (`a` then `b` → `a/b`) instead of replacing.
- `scope controller:` is applied to `resources` / `resource` the same way as verb routes.
- Controller inference for multi-segment resource paths joins segments (`/admin/users` → `admin/users`), matching nested-resource convention.

## 0.1.10

### Frontend env map

- Declarative map (`frontend/env.yml` or `.belt/frontend_env.yml`) maps process env names → terraform output names (framework-agnostic: `VITE_*`, `REACT_APP_*`, `NEXT_PUBLIC_*`, etc.)
- `belt deploy frontend <env>` injects mapped vars into `npm run build` process env
- `belt frontend env <env>` smart-merges mapped keys into `frontend/.env` (preserves unmapped keys/comments; missing TF outputs warn and do not clobber)
- No map → previous default: only `VITE_API_URL` ← `api_url`
- `belt server` uses the same map for local process env

## 0.1.4

### Bug fixes

- Accept optional `environment` keyword on terraform commands so `belt destroy environment dev` works (mirrors `belt generate environment`). Short form `belt destroy dev` still works.
- Sanitize app names for S3 bucket names in `belt setup state` (and env/frontend templates): underscores are converted to hyphens so names like `my_app` produce valid buckets (`my-app-terraform-state`)

## 0.1.1

### `belt routes` CLI command

- Added `belt routes` — displays all routes defined in `infrastructure/routes.tf.rb`
- Concise table output with VERB, PATH, CONTROLLER#ACTION (shows GATEWAY/LAMBDA columns when multiple namespaces exist)
- JSON output via `--format json` includes routes array and optional schema models
- Filter routes with `--grep PATTERN` (case-insensitive, matches verb, path, gateway, lambda, controller, or action)
- Generate Ruby route manifest files with `--namespace NAMESPACE` (or `all` for every gateway/lambda)
- `--output-dir DIR` controls where generated files are written (warns if used without `--namespace`)
- Added `Belt.root` — project root detection by walking up to find `infrastructure/routes.tf.rb`, with fallback to `pwd`
- Default output directory for generated routes: `#{Belt.root}/lambda/lib/routes`

### `belt tasks` CLI command

- Added `belt tasks` — lists available rake tasks from the project's Rakefile
- Filter tasks with `--grep PATTERN`
- Show all tasks (including undescribed) with `--all`
- Run rake tasks directly: `belt lambda:build_layer` invokes `bundle exec rake lambda:build_layer`

### Other changes

- Added `Belt::RouteDSL` — full route DSL parser (resources, nested resources, scopes, mounts, schemas)
- Added `Belt::TableInference` — infers DynamoDB table access from Terraform definitions
- Renamed `TerraDispatch` references to `Belt` in templates and DSL entry points
- Removed `activeitem` dependency from generated Gemfile template
- Added Rakefile template to `belt new` scaffolding

## 0.0.7

- Fixed `discover_gem_paths` to use `Gem.loaded_specs` instead of `Gem::Specification.each` — the latter silently returns nothing on Lambda's vendored bundle layout, causing gem controllers/models to not be found

## 0.0.5

- Eliminated regex from `Belt::ActionRouter` — uses pure segment-by-segment string comparison (resolves CodeQL alerts)

## 0.0.4

- Added `Belt::Holster` — Belt's equivalent of Rails Engines. Gems subclass `Belt::Holster` to provide controllers, models, routes, and schema via convention.
- Added `Belt.all_controller_paths`, `Belt.all_models_paths`, `Belt.all_routes_paths`, `Belt.all_schema_paths` aggregation methods
- `Belt::ActionRouter` now searches holster controller paths automatically

## 0.0.3

- Added `Belt::LambdaHandler` — module for Lambda entry points with observability, CORS preflight, JSON parsing, and error wrapping
- Added `Belt::ActionRouter` — request routing to controllers based on route manifests
- Added `Belt::Observability` — global Logger and Metrics facades for access from anywhere in the codebase

## 0.0.2

- Renamed base class to `BeltController::Base` (mirrors `ActionController::Base`)
- Added `BeltController::Base` with callbacks, strong params, CORS, error handling
- Added `ActionController::Parameters` (strong params without Rails)
- Added response helpers and CORS origin resolution
- Bundled dependencies: activeitem, lambda_loadout
