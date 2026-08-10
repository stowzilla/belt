# Backups

Belt integrates automated pre-deploy backups into the deploy lifecycle.
When configured, `belt deploy` creates recovery points before applying changes.

## Quick Setup

Create `infrastructure/<env>/belt.rb`:

```ruby
Belt.configure do |config|
  config.backups do
    dynamodb :all
    retention snapshots: 90
  end
end
```

Then deploy normally — backups run automatically:

```bash
belt deploy prod
```

## Simple Mode

For DynamoDB-only backups with defaults (all tables, 90-day retention):

```ruby
Belt.configure do |config|
  config.backups = true
end
```

## Full Configuration

```ruby
Belt.configure do |config|
  config.backups do
    dynamodb :all                     # All tables: PITR check + on-demand snapshot
    dynamodb :posts, :users           # Or specific tables only
    cognito :users, :pool_config      # Export user list + pool settings to S3
    s3 :legal_documents               # Sync bucket to backup bucket
    retention snapshots: 90, cognito: 10, s3: 10
  end
end
```

## Backup Types

| Type | What It Does | Default Retention |
|------|-------------|-------------------|
| `dynamodb :all` | PITR verification + on-demand snapshot per table | 90 days |
| `dynamodb :table1, :table2` | Same, specific tables only | 90 days |
| `cognito :users` | Paginated user export → JSON in backup bucket | 10 copies |
| `cognito :pool_config` | Pool configuration export → JSON | 10 copies |
| `s3 :bucket_name` | Full sync to backup bucket | 10 copies |

## CLI Flags

```bash
belt deploy prod                # normal deploy (runs backups first)
belt deploy prod --skip-backup  # skip backup phase
belt deploy prod --backup-only  # just create recovery point, don't deploy
```

## How It Works

1. Creates backup bucket `<app-name>-backups-<env>` on first run (versioned, public access blocked)
2. Reads table names from `terraform output`
3. Verifies PITR is enabled on each DynamoDB table
4. Creates on-demand backup named `<table>-<timestamp>`
5. For Cognito/S3: exports to backup bucket under timestamped prefixes
6. Cleans up expired snapshots/copies beyond retention

## First Deploy

On a brand-new environment with no prior deploys, there are no Terraform outputs
to read table names from. Belt warns and skips the backup phase gracefully.
After the first successful deploy, backups run normally.

## DynamoDB Protection Defaults

All Belt-generated DynamoDB tables include:
- **PITR** (Point-in-Time Recovery) — enabled by default (35 days continuous)
- **Deletion protection** — enabled in prod, disabled in dev

## Skipping Backups in Dev

Don't create `infrastructure/dev01/belt.rb`, or omit the backups block:

```ruby
Belt.configure do |config|
  # No backups block = no backups during deploy
end
```

## See Also

- `belt explain deployment` — the full deploy lifecycle
- `belt deploy --help` — all deploy options
