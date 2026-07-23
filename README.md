# Belt

A Rails-inspired framework for building serverless Ruby applications on AWS Lambda.

Belt bundles everything you need to go from zero to production:

- **BeltController** — callbacks, strong parameters, error handling, CORS
- **Belt::LambdaHandler** — Lambda entry point with observability, CORS preflight, error wrapping
- **Belt::ActionRouter** — request routing to controllers from route manifests
- **ActiveItem** — DynamoDB ORM (queries, validations, associations, transactions)
- **Lambda Loadout** — structured logging, CloudWatch metrics (EMF), error alerting

## Installation

Add to your Gemfile:

```ruby
gem "belt"
```

Then:

```bash
bundle install
```

## Quick Start

### 1. Project structure

```
my-app/
├── infrastructure/
│   ├── routes.tf.rb        # Belt provider route definitions
│   └── schema.tf.rb        # DynamoDB table schemas
├── lambda/
│   ├── config/
│   │   └── environment.rb  # App boot file (used by console + Lambda)
│   ├── controllers/
│   │   └── posts_controller.rb
│   ├── models/
│   │   └── post.rb
│   ├── lib/
│   │   └── routes.rb
│   └── api.rb              # Lambda entry point
├── .irbrc                  # Console customization (optional)
├── Gemfile
└── Gemfile.lock
```

### 2. Define a model

```ruby
require "activeitem"

class Post < ActiveItem::Base
  self.primary_key = :id

  attr_accessor :id, :user_id, :title, :body, :created_at

  validates :title, presence: true
  before_create { self.id ||= SecureRandom.uuid }
end
```

### 3. Write a controller

```ruby
require "belt"

class PostsController < BeltController::Base
  before_action :authenticate!

  def index
    posts = Post.where(user_id: current_user_id, index: "UserIndex")
    success_response(posts.map(&:attributes))
  end

  def show
    post = Post.find(params["id"])
    success_response(post.attributes)
  end

  def create
    attrs = params.require(:post).permit(:title, :body).to_h
    post = Post.create!(attrs.merge(user_id: current_user_id))
    success_response(post.attributes, 201)
  end
end
```

### 4. Lambda entry point

Use `Belt::LambdaHandler` to get automatic observability, CORS preflight handling, and error wrapping:

```ruby
require "belt"

include Belt::LambdaHandler

ROUTER = Belt::ActionRouter.new(routes: Routes::API, namespace: "api")

def execute(path:, body:, event:)
  ROUTER.route(event: event, body: body)
end
```

That's it. `lambda_handler` is automatically your Lambda function handler. It:
- Initializes structured logging and CloudWatch metrics
- Handles OPTIONS preflight requests
- Parses JSON request bodies
- Catches unhandled errors and returns proper CORS-enabled error responses
- Calls your `execute` method for routing

### 5. Configure the Conveyor Belt Terraform provider

The [Conveyor Belt](https://registry.terraform.io/providers/stowzilla/conveyor-belt) Terraform provider (formerly Dispatcher) handles Lambda packaging, API Gateway routing, and IAM permissions.

Add the provider to your Terraform config:

```hcl
terraform {
  required_providers {
    conveyor-belt = {
      source  = "stowzilla/conveyor-belt"
      version = "~> 0.0.1"
    }
  }
}
```

Define routes in `infrastructure/routes.tf.rb`:

```ruby
Belt.application.routes.draw do
  namespace :api do
    resources :posts, only: [:index, :show, :create]
  end
end
```

Define tables in `infrastructure/schema.tf.rb`:

```ruby
Belt.application.schema.define do
  model :post do
    partition_key :id, :string
    global_secondary_index :UserIndex, partition_key: :user_id
  end
end
```

Then deploy:

```bash
terraform init
terraform apply
```

The provider will:
- Package your Ruby code into Lambda functions
- Create API Gateway routes matching your DSL
- Generate IAM policies for DynamoDB table access
- Set up CloudWatch log groups

## BeltController Features

### Callbacks

```ruby
class AdminController < BeltController::Base
  before_action :authenticate!
  before_action :require_admin!, except: [:health]
  skip_before_action :authenticate!, only: [:health]
end
```

### Strong Parameters

```ruby
params.require(:user).permit(:name, :email, address: [:street, :city])
```

### Error Handling

```ruby
class ApiController < BeltController::Base
  rescue_from MyCustomError, with: :handle_custom

  private

  def handle_custom(exception, _context = {})
    error_response(exception.message, 422)
  end
end
```

### Response Helpers

```ruby
success_response({ id: "123", name: "Example" })       # 200 JSON with CORS
success_response({ id: "123" }, 201)                    # 201 Created
error_response("Not found", 404)                        # 404 JSON error
html_response("<h1>Hello</h1>")                         # 200 HTML with CORS
```

## Controller Discovery

Belt discovers controllers from the app's namespace module first, then searches `Belt.all_controller_paths` — which includes app-defined paths. No registration needed.

## Belt::Observability

Belt provides global `Belt::Observability::Logger` and `Belt::Observability::Metrics` facades that are set automatically by `Belt::LambdaHandler`. Access them from anywhere:

```ruby
Belt::Observability::Logger.info("Something happened", user_id: "123")
Belt::Observability::Metrics.track_event("OrderCreated", model: "Order")
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `ENVIRONMENT` | Controls verbose error responses (`dev*`, `local`, `test`) |
| `BELT_METRICS_NAMESPACE` | CloudWatch metrics namespace (default: `Belt`) |
| `ACTION` | Service name for logging (falls back to function name) |
| `ERROR_NOTIFICATION_TOPIC_ARN` | SNS topic for error alerts |
| `CORS_ALLOWED_ORIGINS` | Comma-separated origins (overrides domain vars) |
| `CUSTOMER_APP_DOMAIN` | Primary app domain for CORS |
| `OPS_APP_DOMAIN` | Internal tools domain for CORS |

## CLI

Belt includes a command-line interface for project management.

### `belt console` (alias: `belt c`)

Start an interactive Ruby console with your app loaded. Belt uses convention over configuration:

1. Loads `lambda/config/environment.rb` (your app's boot file — AWS setup, models, libs)
2. Starts IRB with `reload!` available
3. Reads `.irbrc` from the project root (console-specific customization)

```bash
belt console           # uses BELT_ENV or defaults to 'dev'
belt c prod            # specify environment explicitly
belt c dev02 --run "Customer.first"  # runner mode (execute and exit)
```

A production safety prompt is shown when the environment is `prod`.

### `belt routes`

Display route definitions from your `infrastructure/routes.tf.rb`. This is the primary way to inspect what endpoints your app exposes.

```bash
belt routes
```

Output (single namespace):

```
VERB    PATH                   CONTROLLER#ACTION
------------------------------------------------------------------
GET     /posts                 posts#index
GET     /posts/{post_id}       posts#show
POST    /posts                 posts#create
DELETE  /posts/{post_id}       posts#destroy
```

When multiple namespaces (API Gateways) exist, GATEWAY and LAMBDA columns are added automatically:

```
VERB    PATH              GATEWAY  LAMBDA  CONTROLLER#ACTION
---------------------------------------------------------------
GET     /posts            blog     blog    posts#index
POST    /posts            blog     blog    posts#create
GET     /posts            ops      ops     posts#index
POST    /posts            ops      ops     posts#create
```

#### Options

| Flag | Description |
|------|-------------|
| `-g, --grep PATTERN` | Filter routes matching pattern (case-insensitive, matches verb, path, gateway, lambda, controller, or action) |
| `-f, --format FORMAT` | Output format: `concise` (default) or `json` |
| `--namespace NAMESPACE` | Generate Ruby route files for NAMESPACE (or "all") |
| `--output-dir DIR` | Output directory for generated Ruby files (default: `lambda/lib/routes/`) |
| `--schema FILE` | Path to `schema.tf.rb` for model definitions (default: same directory as routes file) |
| `--tables-file FILE` | Path to Terraform file with `aws_dynamodb_table` resources for table inference |
| `-h, --help` | Show help |

#### Examples

```bash
# Filter routes by pattern
belt routes -g posts

# JSON output (for tooling/CI)
belt routes -f json

# Generate Ruby route constant for the "api" namespace
belt routes --namespace api

# Generate to a custom directory
belt routes --namespace api --output-dir lib/routes

# Include schema models in JSON output
belt routes -f json --schema infrastructure/schema.tf.rb

# Infer DynamoDB table access from Terraform
belt routes -f json --tables-file infrastructure/main.tf
```

#### JSON Output

With `--format json`, the output includes a `routes` array and optionally a `models` array (when a schema file is found):

```json
{
  "routes": [
    {
      "name": "posts",
      "verb": "GET",
      "path": "/posts",
      "gateway": "api",
      "lambda": "api",
      "controller": "posts",
      "action": "index",
      "auth": "cognito",
      "tables": ["posts"],
      "request_model": "",
      "response_model": ""
    }
  ],
  "models": [
    {
      "name": "CreatePost",
      "kind": "request",
      "description": "Request model: CreatePost",
      "properties": {
        "title": { "type": "string" },
        "body": { "type": "string" }
      },
      "required": ["title"]
    }
  ]
}
```

#### Ruby Output

With `--namespace NAMESPACE`, Belt generates a frozen Ruby constant file at `lambda/lib/routes/<namespace>_routes.rb`:

```ruby
# frozen_string_literal: true

# Auto-generated by: belt routes --namespace api
# Do not edit manually

module Routes
  API = [
    {
      verb: "GET",
      path: "/posts",
      gateway: "api",
      lambda: "api",
      controller: "posts",
      action: "index",
      auth: "cognito",
      tables: ["posts"]
    }
  ].freeze
end
```

This is used by `Belt::ActionRouter` at runtime for request routing.

#### Route File Location

The command expects `infrastructure/routes.tf.rb` in the current working directory. Routes are defined using the same DSL as the Belt Terraform provider:

```ruby
Belt.application.routes.draw do
  namespace :api do
    resources :posts, only: [:index, :show, :create, :destroy]
    resource :profile, only: [:show, :update]
    get "health", action: :health
  end
end
```

#### Table Inference

When `--tables-file` is provided, Belt parses `aws_dynamodb_table` resource blocks from your Terraform files and infers which tables each route accesses based on the resource name in the route path. Routes can also declare tables explicitly in the DSL via `tables: [:posts, :comments]`.

## Backups

Belt integrates automated pre-deploy backups directly into the deploy lifecycle. No standalone scripts, no generators — `belt deploy` handles everything.

### Quick Start Guide

This walks you through enabling backups for an existing Belt app from scratch.

#### Step 1: Create a backup config

Create `infrastructure/<env>/belt.rb` in your environment directory (e.g. `infrastructure/prod/belt.rb`):

```ruby
# infrastructure/prod/belt.rb
Belt.configure do |config|
  config.backups do
    dynamodb :all
    retention snapshots: 90
  end
end
```

That's the minimum — every DynamoDB table in this environment will get an on-demand snapshot before each deploy, retained for 90 days. PITR (point-in-time recovery) will be verified as enabled.

#### Step 2: Deploy

```bash
belt deploy prod
```

Output:

```
━━━ pre-deploy backup ━━━
  📦 Creating backup bucket: my-app-backups-prod
  ✅ Backup bucket created and secured
  🔍 Verifying PITR: my-app-prod-posts → enabled ✓
  📸 Snapshot: my-app-prod-posts → my-app-prod-posts-20260723-170000 ✓
  🧹 Cleanup: 0 expired snapshots removed

━━━ terraform init ━━━
...
```

The backup bucket is created automatically on first run (versioned, public access blocked). Subsequent deploys reuse it.

#### Step 3: Add more backup types (optional)

As your app grows, add Cognito and S3 backups:

```ruby
# infrastructure/prod/belt.rb
Belt.configure do |config|
  config.backups do
    dynamodb :all                    # On-demand snapshots + PITR verification
    cognito :users, :pool_config    # Export user list + pool settings to S3
    s3 :legal_documents             # Sync bucket contents to backup bucket
    retention snapshots: 90, cognito: 10, s3: 10
  end
end
```

| Backup type | What it does | Retention default |
|-------------|-------------|-------------------|
| `dynamodb :all` | PITR check + on-demand snapshot per table | 90 days |
| `dynamodb :posts, :users` | Same, but only named tables | 90 days |
| `cognito :users` | Paginated user export → JSON in backup bucket | 10 copies |
| `cognito :pool_config` | Pool configuration export → JSON | 10 copies |
| `s3 :bucket_name` | Full sync to backup bucket | 10 copies |

#### Step 4: Keep dev lightweight

Don't configure backups for dev environments — just omit the file or the backups block:

```ruby
# infrastructure/dev01/belt.rb
Belt.configure do |config|
  # No backups block = no backups run during deploy
end
```

Or simply don't create `infrastructure/dev01/belt.rb` at all.

### Simple mode

If you only need DynamoDB backups with all defaults:

```ruby
# infrastructure/prod/belt.rb
Belt.configure do |config|
  config.backups = true
end
```

This enables DynamoDB snapshots for all tables with 90-day retention.

### CLI Flags

| Flag | Description |
|------|-------------|
| `--skip-backup` | Skip backup phase (useful for CI re-runs) |
| `--backup-only` | Run backups without deploying |

```bash
# Normal deploy (runs backups first if configured)
belt deploy prod

# Skip backups this time
belt deploy prod --skip-backup

# Just create a recovery point, don't deploy
belt deploy prod --backup-only
```

### DynamoDB Protection Defaults

All DynamoDB tables generated by Belt include safety defaults:

```hcl
point_in_time_recovery {
  enabled = var.enable_pitr  # true by default
}
deletion_protection_enabled = var.deletion_protection  # true in prod, false in dev
```

These are set via Terraform variables in each environment's `terraform.tfvars`. PITR gives you 35 days of continuous recovery regardless of the snapshot schedule.

### How It Works

1. **Backup bucket** — Belt creates `<app-name>-backups-<env>` on first run (versioned, public access blocked)
2. **Table discovery** — Table names are read from `terraform output` (requires at least one prior successful deploy)
3. **DynamoDB** — Verifies PITR is enabled, then creates an on-demand backup named `<table>-<timestamp>`
4. **Cognito** — Uses `list-users` (paginated) and `describe-user-pool` to export JSON to the backup bucket
5. **S3** — Runs `aws s3 sync` from source bucket to `s3://<backup-bucket>/s3/<bucket-name>/<timestamp>/`
6. **Cleanup** — Removes snapshots/copies older than the configured retention

### First Deploy Note

The backup phase reads table names from Terraform outputs. On a brand-new environment that has never been deployed, there are no outputs yet — Belt will warn and skip the backup phase gracefully. After the first successful deploy, backups run normally on subsequent deploys.

## License

MIT
