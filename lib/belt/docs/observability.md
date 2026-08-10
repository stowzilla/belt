# Observability

Belt provides structured logging and CloudWatch metrics out of the box.
These are initialized automatically by `Belt::LambdaHandler` — no setup required.

## Logging

Access the logger from anywhere:

```ruby
Belt::Observability::Logger.info("Order placed", order_id: "o-123", total: 49.99)
Belt::Observability::Logger.warn("Retry attempt", attempt: 3, service: "payments")
Belt::Observability::Logger.error("Payment failed", error: e.message, order_id: "o-123")
```

Logs are structured JSON, compatible with CloudWatch Logs Insights:

```json
{
  "level": "INFO",
  "message": "Order placed",
  "order_id": "o-123",
  "total": 49.99,
  "timestamp": "2024-01-15T10:30:00Z",
  "service": "api"
}
```

## Metrics

Track custom events via CloudWatch Embedded Metric Format (EMF):

```ruby
Belt::Observability::Metrics.track_event("OrderCreated", model: "Order")
Belt::Observability::Metrics.track_event("PaymentProcessed", amount: 49.99)
```

### Built-in Metrics

The Lambda handler automatically emits:
- `RequestCount` — per invocation
- `ErrorCount` — on unhandled exceptions
- `Latency` — request duration in milliseconds

### Namespace

Metrics are published under the namespace set by `BELT_METRICS_NAMESPACE`
(defaults to `Belt`). View them in CloudWatch → Metrics → Custom namespaces.

## Error Alerting

Set `ERROR_NOTIFICATION_TOPIC_ARN` to an SNS topic ARN. Unhandled errors
will publish a notification with error details (message, backtrace, request context).

```yaml
# config/lambda/api.yml
environment:
  ERROR_NOTIFICATION_TOPIC_ARN: ${var.sns_topic_arn}
```

## CloudWatch Logs Insights

Query structured logs:

```
fields @timestamp, message, order_id
| filter level = "ERROR"
| sort @timestamp desc
| limit 20
```

## Viewing Logs Locally

```bash
belt logs api              # tail logs for the "api" Lambda
belt logs api -f           # follow (live tail)
belt logs api -s 30m       # last 30 minutes
belt logs worker -e prod   # specific environment
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `BELT_METRICS_NAMESPACE` | CloudWatch metrics namespace (default: `Belt`) |
| `ACTION` | Service name in log entries (falls back to function name) |
| `ERROR_NOTIFICATION_TOPIC_ARN` | SNS topic for error alerts |
| `ENVIRONMENT` | Controls verbose errors (`dev*`/`local`/`test` = verbose) |

## See Also

- `belt explain lambda_handler` — how observability is initialized
- `belt explain deployment` — configuring environment variables
- `belt logs --help` — full CLI options for log viewing
