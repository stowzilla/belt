# Data Seeding

Belt provides two ways to get data into an environment without hand-crafting
rows: copying data from another environment, and Rails-style seed files.

## `belt db:copy` — copy data between environments

Copies DynamoDB table contents from one environment into another, matching
tables by name after stripping each environment's `<app>-<env>-` prefix.

```bash
belt db:copy prod dev            # copy prod data into dev
belt db:copy prod dev --force    # overwrite dev tables even if non-empty
```

By default, destination tables that already contain data are skipped — safe
to re-run against a live environment. `--force` overwrites them instead.

### Cognito identity re-anchoring

Cognito identities are **per-environment**: each environment has its own user
pool, so the same person has a *different* `sub` in every environment. Any row
that references a user by their `sub` (e.g. a membership's `cognito_sub`) has a
reference that's meaningless in another environment — copy it verbatim and the
row points at a user who doesn't exist in the destination pool, so it silently
disappears (a copied project you can't see, a member who isn't there).

`belt db:copy` handles this automatically:

- The destination's own `users` table is **left untouched** — the destination
  pool is authoritative for who its users are and what `sub` each one has.
- For every other table, any row carrying both an `email` and a `cognito_sub`
  has its `cognito_sub` **re-anchored** to the destination user with the same
  email.
- A row whose email has no destination user yet has its stale `cognito_sub`
  **cleared**, so it reads as unclaimed (e.g. a pending invitation Belt binds
  on that person's first login) rather than dangling.

```bash
belt db:copy prod dev                     # re-anchors identities (default)
belt db:copy prod dev --no-remap-identity # copy cognito_sub refs verbatim
```

This relies on Belt's `cognito_authenticatable` convention: the users table is
`<app>-<env>-users`, its primary key is `id` (the Cognito `sub`), it carries an
`email`, and `cognito_sub` is the foreign-key attribute referencing it. The
same re-anchoring runs in the nested (PR-preview) environment deploy hook.

### Cross-account copies

Source and destination environments often live in different AWS accounts
(e.g. prod vs. dev). `belt db:copy` resolves the AWS profile for each side
independently from `infrastructure/<env>/belt.rb` (`config.aws_profile`):

```ruby
# infrastructure/prod/belt.rb
Belt.configure do |config|
  config.aws_profile = "prod-readonly"
end
```

Override either side explicitly if you don't want to rely on `belt.rb`:

```bash
belt db:copy prod dev --from-profile prod-readonly --to-profile dev
```

### How it works

1. Lists tables under each environment's prefix (`<app>-<env>-`) using the
   AWS CLI (`aws dynamodb list-tables`)
2. Pairs up tables by matching suffix (e.g. `myapp-prod-posts` ↔ `myapp-dev-posts`)
3. Scans the source table and `batch-write-item`s into the destination,
   re-anchoring Cognito-sub foreign keys to the destination's users by email
   (unless `--no-remap-identity`; see above)
4. Skips (or overwrites, with `--force`) destination tables that already
   have items

This is the same mechanism used by nested (PR-preview) environment deploys
to seed a preview environment's tables from its parent — `belt db:copy` just
exposes it as a standalone command for any two environments.

## `belt db:seed` — Rails-style seed file

Mirrors `rails db:seed`. Loads `config/seeds.rb` in the same booted context
`belt console` uses — your models (ActiveItem) are available, targeting the
resolved environment's tables.

```bash
belt db:seed              # seeds dev, or $BELT_ENV if set
belt db:seed dev01        # explicit environment
belt db:seed prod         # prompts for confirmation, like belt console prod
```

`config/seeds.rb` is a plain Ruby file:

```ruby
# frozen_string_literal: true

post = Post.create!(title: "Hello, world", body: "Seeded post")
puts "Created post: #{post.id}"
```

### Safety

`belt db:seed` refuses to run if the target environment's tables already
have data, to avoid clobbering a live environment (or accidentally reseeding
one that's already loaded). Pass `--force` to seed anyway:

```bash
belt db:seed dev01 --force
```

Because of this guard, seeds are typically run once against a fresh
environment. If you want `seeds.rb` to be safely re-runnable regardless,
write it idempotently (`find_or_create_by`-style) — `belt db:seed --force`
does not enforce idempotency for you.

### Scaffolding

`belt new` generates a starter `config/seeds.rb` with usage notes and an
example. Existing apps can add the file manually — it's just a plain Ruby
file, no generator required.

## See Also

- `belt explain backups` — recovery-point snapshots, not data seeding
- `belt explain console` — the app-booting mechanism `db:seed` reuses
- `belt explain deployment` — nested environments and the parent → child copy hook
