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
2. **Detects the protocol** — HTTP path/verb or WebSocket connection/route key
3. **Handles HTTP OPTIONS preflight** — returns CORS headers immediately
4. **Parses the request body or WebSocket frame** — JSON string → Ruby hash
5. **Calls your `execute` method** — with `path:`, `body:`, and `event:`
6. **Catches unhandled errors** — returns an API Gateway response
7. **Emits metrics** — request count, latency, error count via EMF

## The `execute` Method

You must define `execute` in your Lambda file. It receives:

| Param | HTTP request | WebSocket event |
|-------|--------------|-----------------|
| `path:` | Request path, such as `/posts/123` | Selected route key, such as `$connect` or `subscribe` |
| `body:` | Parsed JSON request body | Parsed JSON frame; `{}` for lifecycle events without a body |
| `event:` | Full API Gateway REST event | Full API Gateway WebSocket proxy event |

Return an API Gateway response hash: `{ statusCode:, headers:, body: }`.
Typically you call `ROUTER.route(...)`, which dispatches either protocol from the
same execute method. The handler never logs WebSocket frames or query parameters,
because `$connect` query parameters may contain a short-lived credential.

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
