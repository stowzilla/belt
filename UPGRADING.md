# Upgrading Belt

Migration notes for moving an existing Belt app between versions. For the full
change list, see [CHANGELOG.md](CHANGELOG.md).

---

## Ruby 3.4 → 4.0

Belt 0.6.0 generates new apps on Ruby 4.0. Existing apps stay on 3.4 until you opt
in — nothing changes underneath you by bumping the gem. The switch itself is one
line per environment; most of this guide is about making it boring.

**What you need**

| Piece | Version | Why |
|-------|---------|-----|
| conveyor-belt | `~> 0.0.16` | Earlier versions only apply `ruby_version` to *newly created* functions; existing ones silently stay on `ruby3.4`. **Required.** |
| belt | `~> 0.6.0` | `belt deploy --rebuild` picks the right build image for a `ruby4.0` function. Required if you use `--rebuild`. |
| lambda_loadout | `0.0.3` | Optional — declares `logger` explicitly. 0.0.2 works on 4.0 too. |

activeitem, belt-pay and belt-messaging need no upgrade; their current releases pass
on Ruby 4.0.

### 1. Run your app on Ruby 4.0 locally

```bash
mise use ruby@4.0        # or rbenv/asdf/chruby, whatever you use
bundle install
bundle exec rspec
```

Do this before touching infrastructure. Your suite on 4.0 is the cheapest place to
find problems — a `LoadError` here is a 500 in Lambda later.

### 2. Fix what Ruby 4.0 removed

The things most likely to bite a Belt app:

**Standard libraries that became bundled gems.** These used to load with a bare
`require`. Under Bundler (which is how Lambda runs your code) they now raise
`LoadError` unless they're in your `Gemfile.lock`:

```
benchmark  fiddle  irb  logger  ostruct  pstore  rdoc  readline  reline
```

Find direct uses in your code:

```bash
grep -rnE "require ['\"](benchmark|fiddle|irb|logger|ostruct|pstore|rdoc|readline|reline)['\"]" lambda/ lib/
```

For each hit, add the gem to your `Gemfile` (`gem "ostruct"`), unless a gem you
already depend on brings it in (`logger` usually arrives via activesupport and
aws-sdk-core).

**`cgi` is mostly gone.** `CGI.escape`, `CGI.unescape` and `CGI.escapeHTML` still
work after `require "cgi"` (Belt relies on this). Everything else — `CGI.parse`,
`CGI::Cookie`, the actual CGI handler — needs `gem "cgi"`.

**`Set` and `Pathname` are core classes now.** `require "set"` is harmless; you can
delete it whenever.

**Native gems get recompiled** in the `build-ruby4.0` image on deploy. If an old
pin in `Gemfile.lock` doesn't build on 4.0 (`bigdecimal`, `nokogiri`, `sqlite3`,
`ffi` are the usual suspects), `bundle update <gem>` it. Step 1 catches most of
these, since you just compiled them locally.

### 3. Bump the conveyor-belt provider

In **both** `infrastructure/modules/app/main.tf` and every
`infrastructure/<env>/main.tf`:

```hcl
conveyor-belt = {
  source  = "stowzilla/conveyor-belt"
  version = "~> 0.0.16"
}
```

`.terraform.lock.hcl` still pins the old version, and `belt deploy` runs a plain
`terraform init`, which won't move past it. Upgrade once per environment:

```bash
cd infrastructure/dev && terraform init -upgrade
```

Deploying now with `ruby_version` unset is a no-op for your functions. That makes
it a good checkpoint: bump the provider and deploy, then change Ruby in a separate
deploy.

### 4. Switch one environment

Start with `dev`. In `infrastructure/dev/main.tf`:

```hcl
provider "conveyor-belt" {
  environment  = var.environment
  aws_region   = var.aws_region
  ruby_version = "4.0"
}
```

`ruby_version` sets **both** the Lambda runtime (`ruby4.0`) and the image your gems
compile in (`public.ecr.aws/sam/build-ruby4.0:latest-x86_64`). If you set a custom
`docker_build_image`, it still wins — point it at a Ruby 4.0 image or remove it.

Then:

```bash
belt deploy dev
```

**What the plan will show.** On refresh, conveyor-belt notices every function's
runtime doesn't match `ruby_version`, so **every Lambda in the environment shows
as changed**. That's expected. On apply, each one is rebuilt in the 4.0 image and
its runtime flipped to `ruby4.0`.

**The swap isn't atomic per function.** conveyor-belt pushes the new code first,
then flips the runtime. For the few seconds between the two calls, a cold start can pair the new code with the old runtime (or vice
versa) and fail to load its bundle. Warm instances keep serving until they're
recycled. On dev, ignore it. On prod, deploy in a quiet window.

### 5. Verify

```bash
# Every function should say ruby4.0
aws lambda list-functions \
  --query "Functions[?starts_with(FunctionName, '<app>-dev')].[FunctionName,Runtime]" \
  --output table

belt logs dev        # watch for LoadError / NameError on cold start
```

Hit a real endpoint for each Lambda (API, workers, webhooks) so each one cold-starts
at least once. A missing gem only shows up when a function first boots, not at deploy
time.

### 6. Roll forward

Repeat step 4 for each remaining environment, `prod` last. Because `ruby_version`
lives in the per-environment `main.tf`, environments can run different Rubies for as
long as you need.

### Rolling back

Set `ruby_version = "3.4"` (or delete the line — 3.4 is the provider default) and
`belt deploy <env>`. The same drift detection rebuilds and flips every function
back.

### Gotchas

- **`belt deploy <env> --rebuild`** builds for the runtime the function is *currently*
  on. Run it after the apply above, not instead of it — `--rebuild` only pushes code,
  it never changes the runtime.
- **Lambda layers.** Anything in `lambda_layer_arns` must list `ruby4.0` as a
  compatible runtime and ship its gems under `ruby/gems/4.0.0/`. A 3.4 layer
  attaches fine and then can't be found at require time. Belt apps bundle their gems
  (including lambda_loadout), so this only matters for layers you added yourself.
- **CI.** If your app's workflow pins `ruby-version: '3.4'`, bump it, or run 3.4 and
  4.0 side by side while you migrate.

---

## 0.3.x → 0.4.0

0.4.0 adds first-class Cognito authentication (`cognito_authenticatable`). The
feature is **additive** — nothing in your app breaks by upgrading — but to adopt
it you replace hand-rolled JWT-to-user code with the macro. This guide covers a
clean adoption and the one thing to look at even if you don't.

### 1. Bump the gem

```ruby
# Gemfile
gem "belt", "~> 0.4.0"
```

```bash
bundle update belt
```

If you develop against a local checkout (`gem "belt", path: "../belt"`), just
pull the branch — no version pin to change.

### 2. Heads-up even if you skip auth: `belt setup tables` and `index: false`

0.4.0 fixes a table-generator bug: `belt setup tables` now honours
`belongs_to ..., index: false`. Previously it created the convention GSI anyway,
on a `fooId` attribute your model never writes — an empty index costing storage.

If any model uses `index: false`, regenerating `dynamodb.tf` will **drop those
dead GSIs**. That's a real Terraform diff. Look before you apply:

```bash
belt setup tables
terraform plan   # confirm the only removals are empty convention indexes
```

> **`belt setup tables` overwrites `dynamodb.tf` wholesale.** It regenerates the
> file from your models every run, so a table or GSI you added to `dynamodb.tf`
> **by hand** — not declared on a model — is invisible to the generator and gets
> dropped. Dropping a live, populated GSI is not harmless: queries against it
> start failing. As of this release the generator detects hand-added tables/GSIs
> that would disappear and refuses (or, interactively, prompts) before
> overwriting; pass `--force` to overwrite anyway. Still, always `terraform plan`
> and read the removals before you apply.

Nothing to do if you don't use `index: false`.

### 3. Adopt `cognito_authenticatable` (optional)

If your app already turns Cognito claims into a user record by hand, you can
delete most of that and lean on the macro.

**Fastest path — let the generator do it:**

```bash
belt generate auth
```

This writes `lambda/models/user.rb` (it will **not** overwrite an existing
`user.rb`), regenerates `infrastructure/modules/app/dynamodb.tf` so the `users`
table and its `EmailIndex` exist, and creates the Cognito pool Terraform. Review
the diff, then `terraform plan` / `apply`.

**Manual path — declare the macro on your existing model:**

```ruby
class User < ApplicationRecord
  cognito_authenticatable
end
```

That one line supplies:

- the Cognito `sub` as primary key,
- identity attributes `email`, `name`, `role`, `email_verified`, `last_seen_on`,
- an `EmailIndex` GSI,
- `.sync_from_claims!`, `.for_sub`, `.for_email`, and `#admin?`,
- just-in-time provisioning (first authenticated request writes the row; later
  requests write only on drift).

Then strip the code the macro replaces: your bespoke `find_or_create_by_sub`,
claim-parsing helpers, and any manual `EmailIndex` wiring.

#### Table requirements

The `users` table needs a `hash_key` of `id` (the Cognito sub) and an
`EmailIndex` GSI on `email`. `belt setup tables` generates this from the macro —
you don't need an explicit `indexes()` call. If you manage the table by hand:

```hcl
resource "aws_dynamodb_table" "users" {
  name         = "${var.app_name}-${var.environment}-users"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute { name = "id"    type = "S" }
  attribute { name = "email" type = "S" }

  global_secondary_index {
    name            = "EmailIndex"
    hash_key        = "email"
    projection_type = "ALL"
  }
}
```

#### IAM: grant the users table to every Lambda

Authenticated requests read the users table **before** the action runs, so a
per-route `tables:` list means naming it on every route — and a 401/500 on
whichever one you miss. Grant it gateway-wide rather than per route.

### 4. Controller helpers come for free

`BeltController::Base` now mixes in `current_user`, `user_signed_in?`,
`authenticate_user!`, and `cognito_admin?` with no `include` and no config.

```ruby
class ProfilesController < ApplicationController
  before_action :authenticate_user!

  def show
    @profile = current_user
  end
end
```

`authenticate_user!` raises `Belt::Authentication::NotAuthenticated`, which Belt
maps to **401**.

If you already define methods named `current_user` / `authenticate_user!` in an
`ApplicationController`, remove yours and let the mixin provide them — or keep
yours; a locally-defined method still wins. Check for name collisions before
deleting anything.

### 5. Configuration (only if your defaults differ)

Everything has a working default. An app whose model is `User` and whose staff
group is `admins` configures nothing. Override in
`lambda/config/environment.rb`:

```ruby
Belt.configure do |config|
  config.authentication.user_class   = 'Account'  # default: 'User'
  config.authentication.admin_groups = %w[staff]  # default: ['admins'] (or ADMIN_COGNITO_GROUPS)
  config.authentication.issuer       = '...'      # default: derived from COGNITO_USER_POOL_ID
end
```

Macro options if the defaults don't fit:

```ruby
cognito_authenticatable roles: %w[member admin support],
                        default_role: 'member',
                        email_index: 'PeopleEmailIndex' # or false to skip it
```

### 6. Verify

```bash
belt setup tables
terraform plan          # review users table + any dead-GSI removals
bundle exec rspec       # if your app has a suite
belt deploy <env>
```

Full reference — the `after_cognito_sync` hook, platform staff, and how both
token shapes (API Gateway authorizer vs. raw `Authorization: Bearer`) are
handled — lives in `belt explain authentication` and the README's Authentication
section.
