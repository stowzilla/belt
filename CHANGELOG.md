# Changelog

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
