# Belt CLI reference

Run `belt --help` for the live list, or `belt <command> --help` for a specific
command. `belt explain <topic>` gives conceptual docs. `BELT_ENV` sets the
default environment so you can omit the `<env>` argument.

## Commands

| Command | What it does |
|---|---|
| `belt new <app> [--frontend react]` | Create a new Belt app. `-v` lists every created file. |
| `belt generate <thing> <name>` (alias `g`) | Generate `scaffold`, `model`, `controller`, `frontend`, `views`, `environment`, `dns`, `auth`, or a plugin generator. |
| `belt destroy <thing> <name>` (alias `d`) | Remove what `generate` created. |
| `belt routes [-g PATTERN] [-f json] [--namespace N]` | Show/inspect routes; generate Ruby route constants for the runtime router. |
| `belt contracts [-g PATTERN] [-f json]` | Show API request/response contracts. |
| `belt lambda-config [-e ENV] [-f json\|terraform]` | Show merged Lambda configuration. |
| `belt console [env]` (alias `c`) | Interactive IRB with the app booted. `--run "expr"` for runner mode. |
| `belt logs [lambda] [-f] [-s 5m] [-e env]` | Tail Lambda logs. |
| `belt tasks [-g PATTERN] [-a]` (alias `-T`) | List rake tasks. Any rake task can be run directly: `belt lambda:build_layer`. |
| `belt setup <state\|tables <env>\|frontend>` | Create S3 state bucket / generate DynamoDB tables / frontend infra. |
| `belt doctor` | Check system deps + AWS config. |
| `belt plugin new <name>` | Scaffold a Belt plugin gem. |
| `belt explain <topic>` | Explain a concept (see topic list below). |
| `belt deploy [env] [--auto] [--skip-backup] [--backup-only]` | Deploy to AWS (init → plan → apply, runs backups first if configured). |
| `belt deploy frontend <env> [--frontend NAME]` | Build + deploy frontend(s). |
| `belt dns <deploy\|add <env>\|show>` | Manage the root DNS zone. |
| `belt frontend <env <env>\|list>` | Write `<frontend>/.env` from TF outputs, or list frontends. |
| `belt server [--frontend NAME]` (alias `s`) | Start local dev server. |
| `belt db:copy <from> <to> [--force]` | Copy DynamoDB data between environments. |
| `belt db:seed [env] [--force]` | Run `config/seeds.rb` against an environment. |
| `belt version` | Show Belt version. |

### Terraform shorthand

`belt <action> [env]` maps to Terraform: `init`, `plan`, `apply`, `destroy`,
`output`. Example: `belt apply wups`, `belt output prod`.

> ⚠ `belt destroy` is ambiguous: `belt destroy <env>` runs terraform destroy,
> while `belt destroy scaffold post` removes generated code. Belt disambiguates
> by argument shape.

## `belt explain` topics

`routing`, `controllers`, `models`, `deployment`, `generators`,
`lambda_handler`, `observability`, `console`, `backups`, `data_seeding`,
`plugins`, `structure`, `frontend`, `authentication`.

## Standalone vs project commands

These run anywhere (no Belt project needed): `new`, `version`, `doctor`,
`explain`. All others chdir to the detected project root first.

## Environment variables

| Variable | Purpose |
|---|---|
| `BELT_ENV` | Default environment for env-scoped commands |
| `ENVIRONMENT` | Verbose error responses (`dev*`, `local`, `test`) |
| `BELT_METRICS_NAMESPACE` | CloudWatch metrics namespace (default `Belt`) |
| `ACTION` | Service name for logging (falls back to function name) |
| `ERROR_NOTIFICATION_TOPIC_ARN` | SNS topic for error alerts |
| `CORS_ALLOWED_ORIGINS` | Comma-separated origins (overrides domain vars) |
| `CUSTOMER_APP_DOMAIN` / `OPS_APP_DOMAIN` | CORS domains |

## Common flows

```bash
belt new blog --frontend react
belt generate scaffold post title:string content:text
belt routes
belt deploy dev
belt deploy prod --auto
belt console prod --run "Post.count"
belt logs api -f -e prod
belt db:copy prod dev
```
