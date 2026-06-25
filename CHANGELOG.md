# Changelog

## 0.1.1

### `belt routes` CLI command

- Added `belt routes` — displays all routes defined in `infrastructure/routes.tf.rb`
- Concise table output with VERB, PATH, CONTROLLER#ACTION (shows GATEWAY/LAMBDA columns when multiple namespaces exist)
- JSON output via `--format json` includes routes array and optional schema models
- Filter routes with `--grep PATTERN` (case-insensitive, matches verb, path, gateway, lambda, controller, or action)
- Generate Ruby route manifest files with `--namespace NAMESPACE` (or `all` for every gateway/lambda)
- `--output-dir DIR` controls where generated files are written (warns if used without `--namespace`)
- Added `Belt.root` — project root detection by walking up to find `infrastructure/routes.tf.rb`, with fallback to `pwd`
- Default output directory for generated routes: `#{Belt.root}/lambda/lib/routes`

### `belt tasks` CLI command

- Added `belt tasks` — lists available rake tasks from the project's Rakefile
- Filter tasks with `--grep PATTERN`
- Show all tasks (including undescribed) with `--all`
- Run rake tasks directly: `belt lambda:build_layer` invokes `bundle exec rake lambda:build_layer`

### Other changes

- Added `Belt::RouteDSL` — full route DSL parser (resources, nested resources, scopes, mounts, schemas)
- Added `Belt::TableInference` — infers DynamoDB table access from Terraform definitions
- Renamed `TerraDispatch` references to `Belt` in templates and DSL entry points
- Removed `activeitem` dependency from generated Gemfile template
- Added Rakefile template to `belt new` scaffolding

## 0.0.7

- Fixed `discover_gem_paths` to use `Gem.loaded_specs` instead of `Gem::Specification.each` — the latter silently returns nothing on Lambda's vendored bundle layout, causing gem controllers/models to not be found

## 0.0.5

- Eliminated regex from `Belt::ActionRouter` — uses pure segment-by-segment string comparison (resolves CodeQL alerts)

## 0.0.4

- Added `Belt::Holster` — Belt's equivalent of Rails Engines. Gems subclass `Belt::Holster` to provide controllers, models, routes, and schema via convention.
- Added `Belt.all_controller_paths`, `Belt.all_models_paths`, `Belt.all_routes_paths`, `Belt.all_schema_paths` aggregation methods
- `Belt::ActionRouter` now searches holster controller paths automatically

## 0.0.3

- Added `Belt::LambdaHandler` — module for Lambda entry points with observability, CORS preflight, JSON parsing, and error wrapping
- Added `Belt::ActionRouter` — request routing to controllers based on route manifests
- Added `Belt::Observability` — global Logger and Metrics facades for access from anywhere in the codebase

## 0.0.2

- Renamed base class to `BeltController::Base` (mirrors `ActionController::Base`)
- Added `BeltController::Base` with callbacks, strong params, CORS, error handling
- Added `ActionController::Parameters` (strong params without Rails)
- Added response helpers and CORS origin resolution
- Bundled dependencies: activeitem, lambda_loadout
