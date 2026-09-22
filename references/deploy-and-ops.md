# Deploy, environments, backups, seeding & observability

Run `belt explain deployment`, `belt explain backups`, `belt explain
data_seeding`, and `belt explain observability` for canonical docs.

## Deploy lifecycle

`belt deploy [env]` runs pre-deploy backups (if configured) → terraform init →
plan → apply. The **conveyor-belt** Terraform provider packages Ruby into
Lambdas, creates API Gateway routes from the routing DSL, generates IAM for
DynamoDB access, and sets up CloudWatch log groups.

```bash
belt deploy dev
belt deploy prod --auto          # skip confirmation
belt deploy prod --skip-backup   # CI re-runs
belt deploy prod --backup-only   # recovery point, no deploy
```

Provider config (Terraform):

```hcl
terraform {
  required_providers {
    conveyor-belt = { source = "stowzilla/conveyor-belt", version = "~> 0.0.1" }
  }
}
```

## Environments

Each env has `infrastructure/<env>/` (main.tf, backend.tf, variables.tf,
terraform.tfvars, outputs.tf, belt.rb). Create with `belt generate environment
<name> [parent]`. Terraform shorthand: `belt init|plan|apply|destroy|output <env>`.
Set `BELT_ENV` to omit the env arg.

## Backups (pre-deploy, config-driven)

`infrastructure/<env>/belt.rb`:

```ruby
Belt.configure do |config|
  config.backups do
    dynamodb :all                 # PITR check + on-demand snapshot per table
    cognito  :users, :pool_config # export to backup bucket
    s3       :legal_documents     # sync to backup bucket
    retention snapshots: 90, cognito: 10, s3: 10
  end
end
```

Simple mode: `config.backups = true` (DynamoDB, all tables, 90-day retention).
Omit the block entirely for lightweight dev envs. Belt auto-creates
`<app>-backups-<env>` (versioned, public access blocked) on first run. Table
names come from `terraform output`, so the first-ever deploy skips backups.

## Data seeding

```bash
belt db:copy prod dev [--force]  # copy DynamoDB between envs (matches by stripped prefix)
belt db:seed [env] [--force]     # run config/seeds.rb in the booted console context
```

`db:copy` skips non-empty destination tables by default. `db:seed` refuses to
run against an env that already has data unless `--force`.

## Observability

`Belt::LambdaHandler` wires these global facades automatically:

```ruby
Belt::Observability::Logger.info("Something happened", user_id: "123")
Belt::Observability::Metrics.track_event("OrderCreated", model: "Order")
```

Backed by `lambda_loadout` (structured logging + CloudWatch EMF metrics + error
alerting via `ERROR_NOTIFICATION_TOPIC_ARN`).
