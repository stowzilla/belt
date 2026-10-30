# Data Migrations

`belt setup tables` handles the *shape* of a table (keys, GSIs). Data
migrations handle the *rows already in it*: backfilling a new attribute, or
populating a new index for records written before it existed.

They live in `db/migrate/`, run automatically after `belt deploy <env>`, and
each one runs **exactly once per environment** — prod, dev and every nested
(PR-preview) env keep their own history.

## Writing a migration

One file per migration, named `<timestamp>_<snake_case_name>.rb`, defining a
`Belt::Migration` subclass named after the file:

```ruby
# db/migrate/20261030120000_index_usernames.rb
class IndexUsernames < Belt::Migration
  def up
    PoshNosh::MatchStore.new.index_usernames!
    say 'usernames indexed'
  end
end
```

`up` runs in the same booted app context as `belt console`
(`lambda/config/environment.rb`, or `lambda/lib` + `lambda/models`), with
`ENVIRONMENT` set to the target env, so models talk to that env's tables.
`say` prints an indented progress line.

Use `date -u +%Y%m%d%H%M%S` for the timestamp. Migrations run in timestamp
order.

## Running them

```bash
belt deploy dev                  # runs pending migrations after terraform apply
belt deploy dev --skip-migrations

belt db:migrate                  # dev, or $BELT_ENV if set
belt db:migrate dev01
belt db:migrate prod             # prompts for confirmation (--yes to skip)
belt db:migrate:status prod      # which versions are up / down
```

```
 Status   Migration ID    Migration Name
--------------------------------------------------
  up      20261030120000  Index usernames
  down    20261102090000  Backfill display names
```

During `belt deploy`, migrations run after terraform apply and the
nested-environment data copy (so rows copied from the parent get migrated
too), and before the frontend deploy. They also run after
`belt deploy --rebuild`. Nothing happens if `db/migrate/` is empty.

## Where history is kept

Each applied version is an SSM parameter:

```
/belt/<app>/<env>/schema_migrations/<version>   → {"name": "...", "applied_at": "..."}
```

It lives in SSM rather than a DynamoDB table so `belt db:copy` and the
nested-env copy (which move every `<app>-<env>-*` table) don't carry one env's
history into another. The deploying credentials need
`ssm:GetParametersByPath` and `ssm:PutParameter` on `/belt/<app>/*`.

To re-run a migration, delete its parameter:

```bash
aws ssm delete-parameter --name /belt/myapp/dev/schema_migrations/20261030120000
```

## Failures

A version is recorded only after `up` returns. If one raises, it and every
later migration stay pending, and the command exits non-zero. In
`belt deploy` the infrastructure is already live, so the deploy carries on
(frontend included), prints a warning and exits 1 at the end. Fix the
migration and run `belt db:migrate <env>`.

## Write them idempotent and batch-safe

Migrations run against live data, often while the previous code is still
serving requests:

- **Idempotent.** A migration that dies halfway is re-run from the start, and
  two overlapping deploys can both run it. Only write rows that still need
  the change, and make writes safe to repeat (set a value, don't increment).
- **Batch-safe.** A GSI created in the same deploy may still be backfilling,
  so don't query the index you're populating — page through the base table
  and write in small batches. Expect throttling on big tables.
- **Data only.** Keys, GSIs and table settings belong in Terraform
  (`belt setup tables`). The deployed code should work both before and
  after a migration runs.

## See Also

- `belt explain data_seeding` — `db:copy` and `db:seed`
- `belt explain console` — the app-booting mechanism migrations reuse
- `belt explain deployment` — the full deploy lifecycle
