# Changelog

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
- Bundled dependencies: activeitem, lambda_loadout, s3arch
