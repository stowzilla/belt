# Changelog

## 0.3.32

### Enhancement

- **`belt destroy environment --full` for fully non-interactive teardown**: Added
  a `--full` / `-y` flag that tears an environment down with zero prompts —
  intended for CI pipelines and agents that spin up ephemeral per-PR
  environments and destroy them on merge. Unlike `--force` (which skips
  terraform and only removes local files), `--full` **always runs
  `terraform destroy`** when terraform state is present, then deletes the local
  `infrastructure/<env>/` files. It also auto-continues past the nested-children
  warning. When no terraform state exists there is nothing to tear down, so the
  destroy step is skipped and only the files are removed.

  ```bash
  belt destroy environment pr-1234 --full
  ```

## 0.3.31

### Bug Fix

- **`belt destroy environment` now uses the environment's AWS profile**: The
  terraform destroy path (and remote-state detection) previously inherited
  whatever `AWS_PROFILE` was in the shell, which could point at the wrong
  account and fail with "No valid credential sources found". It now loads
  `infrastructure/<env>/belt.rb` and applies the configured `aws_profile` and
  env vars before running terraform — matching `belt deploy` and
  `belt terraform`.

## 0.3.16

### Enhancement

- **`belt generate auth --ses-email` for custom email domains**: By default,
  Cognito sends verification emails from `no-reply@verificationemail.com`.
  The new `--ses-email` flag configures Cognito to use Amazon SES instead,
  allowing you to send from your own domain (e.g., `noreply@yourapp.com`).
  
  The generator creates:
  - `cognito_variables.tf` with variables for SES email ARN, from address, and
    optional reply-to address
  - `email_configuration` block in `cognito.tf` with `DEVELOPER` sending mode
  - Example variable values in environment tfvars files
  
  Prerequisites:
  1. Verify your domain or email address in Amazon SES
  2. Move out of SES sandbox for production use
  
  Usage: `belt g auth --ses-email`

## 0.3.15

### Bug Fix

- **`belt generate auth` NEW_PASSWORD_REQUIRED challenge sent `email` even when
  the user already had it**: The 0.3.14 fix always passed `{ email }` to
  `completeNewPasswordChallenge`. That fixed pools where `email` was missing, but
  broke the common case where the user already has `email` set (e.g. created via
  `admin-create-user` with an email) — Cognito rejects that with a 400
  `NotAuthorizedException: Cannot modify an already provided email`. The template
  now reads the `requiredAttributes` list Cognito provides in the
  `newPasswordRequired` callback and supplies `email` **only when Cognito actually
  requires it**. Users with email already set complete the challenge without
  re-sending it; users missing email still get it supplied. Handles both cases.

## 0.3.14

### Bug Fix

- **`belt generate auth` NEW_PASSWORD_REQUIRED challenge dropped the email
  attribute**: The generated `auth.js` `completeNewPassword` passed an empty
  attributes object (`{}`) to `completeNewPasswordChallenge`. On user pools that
  require `email`, admin-created users completing the `NEW_PASSWORD_REQUIRED`
  challenge (which don't have `email` set yet) got a 400 `Invalid attributes
  given, email is missing`. The template now supplies `{ email }` (the username
  is the email) so the challenge completes. `Login.jsx` already passed the email
  in, so no change was needed there.

## 0.3.13

### Security Fix

- **`belt generate auth` sent passwords in plaintext**: The generated `auth.js`
  used the raw `@aws-sdk/client-cognito-identity-provider` with
  `AuthFlow: 'USER_PASSWORD_AUTH'`, which puts the user's cleartext `PASSWORD` in
  the `InitiateAuth` request payload (visible in devtools, proxies, and any request
  logging). The template now uses `amazon-cognito-identity-js`, which authenticates
  via SRP (Secure Remote Password) — the password never leaves the browser, only the
  `SRP_A` proof is transmitted. `signIn` and the `NEW_PASSWORD_REQUIRED` challenge now
  run over SRP; `signUp`/`confirmSignUp` are unchanged in behavior but route through the
  same library.
- The generator now installs `amazon-cognito-identity-js` instead of
  `@aws-sdk/client-cognito-identity-provider`.
- SRP requires the User Pool ID client-side, so `auth.js` now reads
  `VITE_COGNITO_USER_POOL_ID` (already emitted by the auth generator's terraform
  outputs and present in `env.yml.example`).

## 0.3.12

### Bug Fix

- **`env.yml.example` Cognito client ID typo**: The example env map referenced
  `cognito_user_pool_client_id` as the terraform output name for
  `VITE_COGNITO_CLIENT_ID`, but the correct output name is `cognito_client_id`.
  Users following the tutorial would uncomment the line and get a missing-output
  warning on deploy. Fixed in the template, CLI help text, and docs.

## 0.3.11

### Bug Fix

- **`belt deploy` skips route generation on first deploy**: The `generate_routes`
  method would silently bail if `lambda/lib/routes/` didn't already exist on disk.
  Since this directory is gitignored (it's a generated build artifact), a fresh clone
  or first deploy would package the Lambda without route manifests, causing a
  `LoadError` at cold start. Now creates the directory with `mkdir_p` before running
  route generation.

## 0.3.10

### Bug Fix

- **`api_url` output missing base path for custom domains**: When a custom domain is
  configured (e.g. `api.dev.example.com`), the `api_url` terraform output was missing
  the gateway's base path segment. Conveyor-belt maps each gateway to a base path
  (gateway "api" → path `/api`), so the correct URL is
  `https://api.dev.example.com/api` not `https://api.dev.example.com`. The frontend
  would get the wrong `VITE_API_URL` and hit a 403 on the custom domain root.

## 0.3.9

### Bug Fix

- **`belt setup frontend` with underscored app names**: The 0.3.8 fix placed
  `local.s3_safe_name` in `dns.tf` but `belt setup frontend` only regenerates
  `frontend.tf`, causing an "undeclared local value" error on existing apps.
  The bucket name now uses inline `replace(var.app_name, "_", "-")` directly in
  `frontend.tf`, making it fully self-contained with no cross-file dependency.

## 0.3.8

### Bug Fix

- **S3 bucket naming with underscored app names**: The module template now sanitizes
  `var.app_name` for S3 bucket names by replacing underscores with hyphens. Apps named
  with underscores (e.g. `feature_parity`) previously generated invalid bucket names
  since S3 follows DNS naming rules which prohibit underscores.

## 0.3.7

### Bug Fix

- **App name detection in worktrees**: `detect_app_name` now checks
  `infrastructure/*/variables.tf` for `variable "app_name" { default = "..." }`
  before falling back to the directory name. Fixes incorrect Lambda function
  lookups (e.g. `belt logs`) when running from a git worktree whose directory
  name doesn't match the actual app name.

## 0.3.6

### Enhancement

- **Per-action request_model**: `request_model` on `resources` now accepts a Hash
  to specify different validation schemas per action:
  ```ruby
  resources :items, request_model: { create: :create_item, update: :update_item }
  ```
  Symbol style (uniform for all body verbs) still works unchanged.

- **Convention-based request_model inference**: When no explicit `request_model` is
  set on a resource route, `belt routes` auto-discovers matching contracts from
  `contracts.rb` using a naming cascade:
  1. `:<verb>_<gateway>_<singular_resource>` (e.g. `:create_customer_item`)
  2. `:<verb>_<singular_resource>` (e.g. `:create_item`)

  Only applies to body-accepting verbs (POST/PUT/PATCH). Explicit `request_model:`
  always takes priority. No matching contract = no validation (same as before).

- **Convention-based response_model inference**: When no explicit `response_model` is
  set on a resource route, `belt routes` auto-discovers a matching response model
  from `contracts.rb` using the singular resource name.
  e.g. `resources :items` → looks for `model :item` → auto-wires `response_model: :item`.
  Applies to all verbs. Explicit `response_model:` always takes priority.

## 0.3.5

### Enhancement

- **Multiple frontends**: Frontend directory is no longer hardcoded to `frontend/`.
  Declare named SPAs in `config/frontends.yml` (path, dist dir, terraform output names).
  `belt generate frontend react --name ops --path ops-app` scaffolds an additional app.
  Generators, `belt server`, `belt frontend env`, and `belt deploy frontend` accept
  `--frontend NAME`. `belt deploy frontend <env>` deploys all configured frontends;
  pass `--frontend` to target one. Existing single-`frontend/` apps keep working
  with no config file.
- **Sidecar Lambda zips**: `belt deploy` / `belt plan` / `belt apply` build zip
  artifacts that Terraform `filebase64sha256` needs at plan time (e.g. Stowzilla's
  Node `image-processor`). Node packages are installed in Docker on linux/amd64
  so native addons match Lambda. Missing zips are built automatically; unchanged
  sources skip the rebuild.

### Bug fix

- **Frontend CloudFront invalidation**: `belt deploy frontend` no longer prints
  terraform's "output not found" error when a named frontend sets
  `cloudfront_domain_output` instead of a distribution-id output. Missing
  terraform outputs are read with stderr silenced.

## 0.3.4

### Enhancement

- **Flexible config file extensions**: Lambda config files (`config/lambda/*.yml`) and frontend env maps (`frontend/env.yml`, `.belt/frontend_env.yml`) now also accept `.yaml` as a file extension. (#1124)

## 0.3.2

### Bug fix

- **Table name normalization**: Route JSON output now uses hyphens instead of underscores in inferred table names, matching the ActiveItem convention (e.g., `user-sessions` instead of `user_sessions`). (#51)

## 0.3.1

Version bump only — tagged release for internal tracking.

## 0.3.0

Version bump only — no code changes from 0.2.21.

**Why 0.3.0 instead of another patch?** The route DSL changes in 0.2.21 (`gateway`/`function`/`namespace`/`scope`) were a minor-version level change (new features, new keywords). RubyGems doesn't allow republishing the same version, so we're bumping to 0.3.0 to correct the semver trajectory.

If you're on 0.2.21, you already have the DSL changes. This release is purely for version hygiene.

## 0.2.21

### Route DSL: `gateway`, `function`, `namespace`, and `scope` keywords

The route DSL now uses terminology that matches AWS infrastructure:

- **`gateway`** — Creates an API Gateway with a default Lambda function of the same name (replaces top-level `namespace`)
- **`function`** — Targets enclosed routes to a different Lambda function
- **`namespace`** — Rails-like path + module prefix (e.g., `/admin/users` with `admin/users` controller). Does NOT change Lambda target.
- **`scope`** — Flexible grouping with `path:`, `module:`, `auth:`, `tables:` options. Does NOT change Lambda target.

```ruby
Belt.application.routes.draw do
  gateway :api, auth: :cognito do
    resources :posts                    # → lambda: "api", path: /posts

    function :onboarding do
      resources :steps                  # → lambda: "onboarding", path: /steps
    end

    namespace :admin do
      resources :users                  # → lambda: "api", path: /admin/users, controller: "admin/users"
    end

    scope path: 'v2', module: 'v2' do
      resources :widgets                # → lambda: "api", path: /v2/widgets, controller: "v2/widgets"
    end
  end
end
```

**ActionRouter** now accepts `gateway:` keyword (preferred):

```ruby
ROUTER = Belt::ActionRouter.new(routes: Routes::API, gateway: 'api')
```

**100% backward compatible:** `namespace :api do` at top level still works (aliased to `gateway`), and `ActionRouter.new(namespace: 'api')` still works.

## 0.2.18

### New generator: `belt generate auth`

Scaffolds Cognito user pool infrastructure for authentication. Creates the user pool, client, and wires `cognito_user_pool_arns` into the conveyor-belt resource automatically.

```bash
belt g auth                    # Single pool: "main"
belt g auth web mobile         # Multiple pools (e.g., web + mobile clients)
belt g auth web android ios    # Three pools
belt destroy auth              # Remove generated files
```

What it generates:
- `infrastructure/modules/app/cognito.tf` — User pool + client with sensible defaults (password policy, email verification, deletion protection in prod)
- `infrastructure/modules/app/cognito_outputs.tf` — Pool ID, ARN, and client ID outputs
- Patches `main.tf` to pass `cognito_user_pool_arns` to the conveyor-belt resource

Multiple pools are supported out of the box — each gets a suffixed name (e.g., `myapp-prod-web`, `myapp-prod-mobile`) and its own set of outputs.

## 0.2.12

### Rename: `routes.tf.rb` → `routes.rb`, `schema.tf.rb` → `contracts.rb`

The `.tf.rb` extension was a vestige of when these files produced HCL output — that hasn't been the case for a while. New apps now get clean, Rails-familiar names:

- `config/routes.rb` — API route definitions
- `config/contracts.rb` — API request/response contracts

**Backward compatible:** All detection helpers (`Belt.root`, `Belt.routes_file`, `Belt.contracts_file`, `find_routes_file_path`, `find_contracts_file_path`) check new names first, then fall back to `*.tf.rb` and `infrastructure/` paths. Existing apps continue working without changes.

### New command: `belt contracts`

Dedicated CLI command for inspecting API contracts, separate from `belt routes`:

```bash
belt contracts                    # Human-readable table of request/response models
belt contracts -f json            # JSON output (for tooling/CI)
belt contracts -g post            # Filter by pattern
belt contracts --file path.rb     # Explicit file override
```

Previously, contracts were only accessible as a side-effect of `belt routes -f json --schema <file>`. Now they have their own first-class command. `belt routes -f json` continues to include models for backward compatibility.

### Other changes

- `Belt.schema_file` is now an alias for `Belt.contracts_file`
- `find_schema_file_path` is now an alias for `find_contracts_file_path`
- Module template updated: `source` points to `config/routes.rb`
- All scaffold/generator help text and templates reference new filenames

## 0.2.13

### Template cleanup

- **Model template**: single-line `attr_accessor` instead of one per attribute; removed redundant `to_h` (ActiveItem::Base already provides it)
- **Controller template**: uses implicit response pattern (instance variable assigns) instead of explicit `success_response` calls; `response_status :created` for create actions, `head :no_content` for destroy
- **Gemfile template**: removed `activeitem` and `lambda_loadout` (already belt gem dependencies)
- **gitignore template**: excludes `lambda/lib/routes/` (generated artifact from `belt routes`)
- **Removed `require 'activeitem'`** from api.rb, environment.rb, and application_record.rb templates (belt requires it transitively)
- **Removed `ActiveItem.configure` boilerplate** from api.rb and environment.rb templates (activeitem 0.0.13+ defaults `table_prefix` and `environment` from ENV vars)
- Bumped activeitem dependency to `>= 0.0.13`

## 0.2.11

### Security hardening

- **CORS origin validation**: format validation (scheme required, no paths/queries/fragments), length limit (253 chars) to prevent ReDoS, restrict wildcard matching to valid subdomain chars `[a-z0-9-]`.
- **Security headers** on all responses: `X-Content-Type-Options: nosniff`, `Vary: Origin`; HTML responses also get `X-Frame-Options: DENY` and `Referrer-Policy: strict-origin-when-cross-origin`.
- **Path traversal protection** in `ActionRouter`: strict regex for controller names, reject `..` sequences / absolute paths / backslashes, `realpath` validation in `resolve_from_paths`.
- **Request body size limit** (10 MB): returns 413 for oversized bodies; proper 400 for invalid JSON.

### Safe `belt destroy environment`

Previously `belt destroy environment <name>` immediately deleted the infrastructure directory with no checks — leaving orphaned AWS resources.

Now the command:
1. Checks if Terraform state exists (local `.terraform` dir or remote state)
2. If state found, prompts user to run `terraform destroy` first
3. Requires explicit confirmation before deleting files
4. Supports `--force` (skip prompts) and `--skip-terraform` flags

### Environment generator state bucket fix

The environment generator was writing `belt-terraform-state` as the backend bucket name, missing the account-ID suffix. Now resolves via sibling `backend.tf`, STS `get-caller-identity`, or placeholder (for later `belt setup state` patch).

### Contributing & plugins

- README: **Plugins** and **Contributing** sections — how to contribute to belt, how plugins register via `GeneratorRegistry`, layout used by `belt-messaging` / `belt-pay`, generator checklist for humans and agents.
- **`belt plugin new <name>`** — scaffold a new plugin gem (gemspec, `Belt::<Name>` module, generator stub, RSpec, README, AGENTS.md), similar to `rails plugin new`.
- **`AGENTS.md`** at the belt gem root — agent-oriented map of core layout, CLI, and the plugin/GeneratorRegistry contract (complements README).
- Plugin scaffold includes **`AGENTS.md`** so new plugins match the agent guidance pattern already used by `belt new` apps.

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
