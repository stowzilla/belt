# Lambda Handler

`Belt::LambdaHandler` is the module you include in your Lambda entry point.
It provides the `lambda_handler` method that AWS Lambda invokes, wrapping
your application logic with observability, CORS, and error handling.

## Basic Usage

```ruby
require "belt"

include Belt::LambdaHandler

ROUTER = Belt::ActionRouter.new(routes: Routes::API, gateway: "api")

def execute(path:, body:, event:)
  ROUTER.route(event: event, body: body)
end
```

## What It Does

When a request arrives, `lambda_handler` automatically:

1. **Initializes observability** — structured logging + CloudWatch metrics
2. **Handles OPTIONS preflight** — returns CORS headers immediately
3. **Parses the request body** — JSON string → Ruby hash
4. **Calls your `execute` method** — with `path:`, `body:`, and `event:`
5. **Catches unhandled errors** — returns a CORS-enabled error response
6. **Emits metrics** — request count, latency, error count via EMF

## The `execute` Method

You must define `execute` in your Lambda file. It receives:

| Param | Description |
|-------|-------------|
| `path:` | The request path (e.g., `/posts/123`) |
| `body:` | Parsed request body (Hash or nil) |
| `event:` | Full API Gateway event (for headers, query params, auth context) |

Return value should be a response hash: `{ statusCode:, headers:, body: }`.
Typically you just call `ROUTER.route(...)` which returns the correct format.

## Multiple Lambdas

If your app has multiple Lambda functions (via `function` in routes):

```ruby
# lambda/worker.rb
require "belt"

include Belt::LambdaHandler

ROUTER = Belt::ActionRouter.new(routes: Routes::WORKER, gateway: "worker")

def execute(path:, body:, event:)
  ROUTER.route(event: event, body: body)
end
```

Each Lambda entry point gets its own route manifest and gateway name.

## Configuration

Configure via `config/lambda/<name>.yml`:

```yaml
handler: lambda/api.lambda_handler
runtime: ruby3.3
timeout: 30
memory: 256
layers:
  - ${var.ruby_layer_arn}
environment:
  ENVIRONMENT: ${var.environment}
  APP_NAME: my-app
  ERROR_NOTIFICATION_TOPIC_ARN: ${var.sns_topic_arn}
```

## Observability

The handler sets up `Belt::Observability::Logger` and `Belt::Observability::Metrics`
automatically. Use them anywhere in your app:

```ruby
Belt::Observability::Logger.info("Order created", order_id: order.id)
Belt::Observability::Metrics.track_event("OrderCreated", model: "Order")
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `ENVIRONMENT` | Controls error verbosity (`dev*`, `local`, `test` = verbose) |
| `BELT_METRICS_NAMESPACE` | CloudWatch namespace (default: `Belt`) |
| `ACTION` | Service name for logging |
| `ERROR_NOTIFICATION_TOPIC_ARN` | SNS topic for error alerts |
| `CORS_ALLOWED_ORIGINS` | Comma-separated allowed origins |

## See Also

- `belt explain routing` — how ActionRouter dispatches requests
- `belt explain controllers` — how dispatched requests are handled
- `belt explain deployment` — Lambda packaging and configuration
