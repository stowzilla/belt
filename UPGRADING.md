# Upgrading Belt

Migration notes for moving an existing Belt app between versions. For the full
change list, see [CHANGELOG.md](CHANGELOG.md).

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
