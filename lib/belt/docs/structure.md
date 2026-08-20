# Project Structure

A Belt application follows a conventional directory layout. Understanding
this structure helps you navigate and extend the app effectively.

## Standard Layout

```
my-app/
├── lambda/                        # Application code (deployed to Lambda)
│   ├── api.rb                     # Lambda entry point
│   ├── config/
│   │   └── environment.rb         # App boot file (models, libs, AWS setup)
│   ├── controllers/
│   │   ├── application_controller.rb
│   │   └── my_app/               # Namespaced controllers
│   │       ├── posts_controller.rb
│   │       └── admin/
│   │           └── users_controller.rb
│   ├── models/
│   │   ├── application_record.rb  # Base model class
│   │   ├── post.rb
│   │   └── concerns/             # Shared model behavior
│   ├── lib/
│   │   └── routes/               # Auto-generated route manifests
│   │       └── api_routes.rb
│   └── Gemfile                    # Lambda-specific dependencies
├── config/
│   ├── routes.rb                  # Route definitions (DSL)
│   ├── contracts.rb               # API request/response contracts
│   └── lambda/                    # Per-lambda configuration
│       └── api.yml                # Timeout, memory, env vars
├── infrastructure/
│   ├── modules/                   # Shared Terraform modules
│   │   └── main/
│   ├── schema.tf.rb               # DynamoDB table schema (Ruby DSL)
│   ├── dev01/                     # Per-environment Terraform
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── terraform.tfvars
│   │   ├── backend.tf
│   │   └── outputs.tf
│   └── prod/
│       └── ...
├── frontend/                      # Optional frontend (React/Vue/Svelte)
├── config/frontends.yml           # Optional: multiple named frontends
├── Gemfile                        # Project-level dependencies (CLI, dev tools)
├── Rakefile                       # Rake tasks
├── AGENTS.md                      # AI agent guide
└── .gitignore
```

## Key Files

### `lambda/api.rb` — Lambda Entry Point

The file AWS Lambda invokes. Includes `Belt::LambdaHandler` and defines `execute`.

### `lambda/config/environment.rb` — Boot File

Loaded by both Lambda and `belt console`. Sets up AWS clients, requires models,
configures the app. Everything your app needs to run.

### `config/routes.rb` — Route Definitions

The Ruby DSL that defines your API. Read by both the Conveyor Belt Terraform
provider (for infrastructure) and `belt routes` (for manifests).

### `config/lambda/api.yml` — Lambda Config

Per-function settings: handler path, runtime, timeout, memory, environment
variables, layers, triggers.

### `infrastructure/schema.tf.rb` — Table Schema

DynamoDB table definitions in Ruby DSL. Used by `belt setup tables` to generate
Terraform resources.

## Conventions

- **Controller namespacing**: Controllers live under `lambda/controllers/<app_name>/`
  to avoid conflicts across modules.
- **Route manifests**: Generated files in `lambda/lib/routes/` — don't edit manually.
  Regenerate with `belt routes --namespace <name>`.
- **Two Gemfiles**: Project root Gemfile is for dev tools (belt CLI, rspec).
  `lambda/Gemfile` is what gets packaged into the Lambda.
- **Config over code**: Lambda configuration (timeout, memory, env vars) goes in
  YAML files, not hardcoded in Terraform.
- **Frontends**: Default directory is `frontend/`. Multiple SPAs (customer + ops,
  etc.) are declared in `config/frontends.yml`. See `belt explain frontend`.

## See Also

- `belt explain routing` — how routes.rb maps to infrastructure
- `belt explain controllers` — controller conventions
- `belt explain deployment` — how this structure gets deployed
