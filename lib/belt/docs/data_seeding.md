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
3. Scans the source table and `batch-write-item`s into the destination
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
