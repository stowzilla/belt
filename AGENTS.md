# AGENTS.md — belt (the gem)

This file is for AI agents (and humans) working **on the belt gem itself**, not on a Belt app.
Belt apps get their own `AGENTS.md` from `belt new` (`lib/templates/new_app/AGENTS.md.erb`).

For end-user docs, see [README.md](README.md). For release notes, see [CHANGELOG.md](CHANGELOG.md).

## What this repo is

Belt is a Rails-inspired framework for serverless Ruby on AWS Lambda. This repository is the **core gem** (`gem "belt"`), which includes:

- Runtime: `BeltController`, `Belt::LambdaHandler`, `Belt::ActionRouter`, params, rendering, observability
- CLI: `exe/belt` → `lib/belt/cli.rb` and commands under `lib/belt/cli/`
- App / plugin scaffolds: ERB templates under `lib/templates/`

Optional capabilities live in **separate plugin gems** (not vendored here): `belt-messaging`, `belt-pay`, etc.

## Stack relationships

| Piece | Role |
|-------|------|
| **belt** (this gem) | CLI + Lambda runtime + generators for apps |
| **activeitem** | DynamoDB ORM (dependency) |
| **lambda_loadout** | Logging / metrics / cold-start helpers (dependency) |
| **conveyor-belt** | Terraform provider; reads Ruby DSL (`routes.tf.rb`) — separate repo |
| **belt-\*** plugins | Optional generators + runtime APIs discovered via `GeneratorRegistry` |

## Repo layout

```
belt/
├── exe/belt                    # CLI entry
├── lib/
│   ├── belt.rb                 # Public require
│   ├── belt/
│   │   ├── cli.rb              # Command dispatch
│   │   ├── cli/                # One file (or folder) per command
│   │   ├── generators/         # (none in core — plugins own these)
│   │   └── …                   # Runtime (handler, router, config, …)
│   ├── belt_controller/        # BeltController::Base + implicit response
│   └── templates/
│       ├── new_app/            # belt new
│       ├── generate/           # built-in generators (resource, model, …)
│       ├── plugin/             # belt plugin new
│       ├── environment/        # belt generate environment
│       └── …
├── spec/                       # RSpec
├── README.md
├── CHANGELOG.md
└── AGENTS.md                   # This file
```

## Common workflows

```bash
bundle install
bundle exec rspec
bundle exec rubocop   # if configured in your env; pre-commit may run it
```

Run the local CLI without installing the gem globally:

```bash
bundle exec exe/belt --help
bundle exec exe/belt plugin new demo --path /tmp
```

Point an app at this checkout while developing:

```ruby
# In a Belt app Gemfile
gem "belt", path: "../belt"
```

`belt deploy` materializes `path:` gems into `vendor/cache` for Lambda packaging.

## CLI map (core)

Commands are registered in `Belt::CLI::COMMANDS_DEFINITION` (`lib/belt/cli.rb`).

| Command | Implementation |
|---------|----------------|
| `new` | `cli/new_command.rb` |
| `generate` / `g` | `cli/generate_command.rb` + built-ins + `GeneratorRegistry` |
| `destroy` / `d` | `cli/destroy_command.rb` |
| `plugin` | `cli/plugin_command.rb` (`plugin new`) |
| `deploy` | `cli/deploy_command.rb` (+ path gem materializer) |
| `doctor` | `cli/doctor_command.rb` |
| `setup` | `cli/setup_command.rb` |
| `console` / `c` | `cli/console_command.rb` |
| Terraform helpers | `cli/terraform_command.rb` (`init` / `plan` / `apply` / `destroy` / `output`) |
| Frontend | `cli/frontend_*.rb` |

When adding a command: require it from `cli.rb`, add it to `COMMANDS_DEFINITION`, document usage in README/CHANGELOG as needed.

## Plugin / GeneratorRegistry contract

Plugins are **not** part of this repo. Core only provides discovery + scaffolding.

**Discovery** (`lib/belt/cli/generator_registry.rb`):

1. Gem is in the host app's Gemfile and loaded
2. File exists at `lib/belt/generators/<name>_generator.rb`
3. Class is `Belt::Generators::<Name>Generator`
4. Implements `.run(args)`; optionally `.destroy(args)` and `.description`

**Scaffold a plugin:**

```bash
belt plugin new notifications
# → belt-notifications/ with gemspec, Belt::Notifications, generator stub, RSpec, AGENTS.md
```

Templates: `lib/templates/plugin/`. Reference implementations: sibling repos `belt-messaging`, `belt-pay`.

**Generator checklist** (what a good plugin generator usually installs into an app):

1. Terraform module → `infrastructure/modules/<name>/`
2. Lambda config → `config/lambda/<name>.yml`
3. Lambda entrypoint → `lambda/<name>.rb` via `Belt::LambdaHandler`
4. Routes / schema injection when needed
5. Optional `--controllers` for app-local overrides
6. Matching `destroy` path
7. `.description` + `--help`

Keep runtime code in the gem; generators copy only what the host app must own.

## App scaffold vs plugin scaffold

| Scaffold | Command | Templates | Ships AGENTS.md? |
|----------|---------|-----------|------------------|
| Belt **app** | `belt new` | `lib/templates/new_app/` | Yes — how to work *in* an app |
| Belt **plugin** | `belt plugin new` | `lib/templates/plugin/` | Yes — how to work *on* a plugin gem |
| **This gem** | — | — | This file |

Do not confuse app `AGENTS.md` guidance (routing, models, deploy) with this file (hacking on belt core / plugins).

## Conventions when changing core

1. Match neighboring code in `lib/belt/cli/` and existing generators
2. Prefer small, focused PRs against `master`
3. Specs under `spec/` for behavior changes
4. User-facing changes → `CHANGELOG.md` under Unreleased / next version
5. Never commit secrets or real account IDs
6. Templates that agents will read (`AGENTS.md.erb`, README scaffolds) should stay accurate when CLI behavior changes

## Where to look first

| Task | Start here |
|------|------------|
| New CLI subcommand | `lib/belt/cli.rb`, then a new `cli/*_command.rb` |
| Change `belt new` output | `cli/new_command.rb` + `templates/new_app/` |
| Change plugin scaffold | `cli/plugin_command.rb` + `templates/plugin/` |
| Built-in generators | `cli/generate_command.rb` + `templates/generate/` |
| Generator discovery bugs | `cli/generator_registry.rb` + `spec/` |
| Controller / response behavior | `lib/belt_controller/` |
| Lambda entry / CORS / errors | `lib/belt/lambda_handler.rb`, helpers under `lib/belt/helpers/` |
| Path gem packaging on deploy | `cli/path_gem_materializer.rb`, `cli/deploy_command.rb` |

## Do not

- Vendor `belt-messaging` / `belt-pay` into this repo — they stay separate gems
- Invent a second plugin registration mechanism — use `GeneratorRegistry` only
- Put app-specific deploy docs here — those belong in the app `AGENTS.md` template
- Publish a gem version for docs-only experiments without an explicit release decision
