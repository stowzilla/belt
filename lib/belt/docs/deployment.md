# Deployment

Belt deploys serverless applications to AWS using Terraform. The CLI wraps
`terraform init/plan/apply` with conventions for environment management,
Lambda packaging, and pre-deploy backups.

## Quick Deploy

```bash
belt deploy <env>              # init → plan → apply (interactive)
belt deploy prod --auto        # skip confirmation prompt
belt deploy prod --skip-backup # skip pre-deploy backup
belt deploy --backup-only      # create recovery point without deploying
```

## First-Time Setup

```bash
# 1. Create S3 bucket for Terraform state
belt setup state

# 2. Scaffold an environment
belt generate environment dev01

# 3. Generate DynamoDB table definitions from schema
belt setup tables dev01

# 4. Initialize and deploy
belt deploy dev01
```

## Environment Structure

Each environment lives in `infrastructure/<env>/`:

```
infrastructure/
├── modules/
│   └── main/            # Shared Terraform module
├── dev01/
│   ├── main.tf          # Module reference + provider
│   ├── variables.tf     # Variable declarations
│   ├── terraform.tfvars # Environment-specific values
│   ├── backend.tf       # S3 state backend
│   └── outputs.tf       # Exported values
└── prod/
    └── ...
```

## What Gets Deployed

The Conveyor Belt Terraform provider reads your Ruby DSL and creates:

1. **API Gateway** — HTTP API with routes matching your DSL
2. **Lambda functions** — packaged Ruby code (one per `gateway`/`function` block)
3. **IAM roles** — least-privilege policies for DynamoDB table access
4. **CloudWatch logs** — log groups for each Lambda
5. **DynamoDB tables** — from your schema definition
6. **Custom domain** — if configured (Route53 + ACM certificate)

## Lambda Packaging

Belt packages the `lambda/` directory plus vendored gems. For `path:` gems
(local development), Belt materializes them into `vendor/cache` automatically.

The Lambda entry point is specified in `config/lambda/<name>.yml`:

```yaml
handler: lambda/<name>.lambda_handler
runtime: ruby3.3
timeout: 30
memory: 256
environment:
  ENVIRONMENT: ${var.environment}
```

## Route Manifests

Before deploying, generate the route manifest used at runtime:

```bash
belt routes --namespace api
# → writes lambda/lib/routes/api_routes.rb
```

This is typically done automatically by `belt deploy`.

## Terraform Commands

Belt wraps Terraform with environment awareness:

```bash
belt init <env>       # terraform init with correct backend
belt plan <env>       # terraform plan
belt apply <env>      # terraform apply
belt destroy <env>    # terraform destroy (careful!)
belt output <env>     # terraform output
```

Or use `belt deploy <env>` which runs init → plan → apply in sequence.

## Pre-Deploy Backups

Configure in `infrastructure/<env>/belt.rb`:

```ruby
Belt.configure do |config|
  config.backups do
    dynamodb :all
    retention snapshots: 90
  end
end
```

Backups run automatically before each deploy (DynamoDB snapshots, Cognito
exports, S3 syncs). See `belt explain backups` for full documentation.

## Environment Variables

Set `BELT_ENV` to avoid typing the environment every time:

```bash
export BELT_ENV=dev01
belt deploy           # uses BELT_ENV
belt deploy prod      # explicit arg wins
```

## Frontend Deployment

For apps with a frontend:

```bash
belt deploy frontend <env>                  # build + deploy all frontends
belt deploy frontend <env> --frontend ops   # deploy one named frontend
belt frontend env <env>                     # generate .env from Terraform outputs
belt frontend list                          # show configured frontends
```

The directory is `frontend/` by default. Multiple SPAs are declared in
`config/frontends.yml` — see `belt explain frontend`. Full `belt deploy <env>`
deploys every configured frontend after terraform apply.

## See Also

- `belt explain routing` — how routes map to infrastructure
- `belt explain backups` — pre-deploy backup configuration
- `belt doctor` — check system dependencies before deploying
