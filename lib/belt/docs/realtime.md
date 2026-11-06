# Realtime WebSocket Push

Belt supports API Gateway WebSocket events as an opt-in push transport. The
`belt-live` plugin supplies connection storage, publishing, infrastructure, and
a browser client. Core Belt supplies the route DSL, Lambda dispatch, and
`Belt::LiveController`.

Use live messages as **nudges**, not as a second data API. A client that receives
a nudge should fetch the resource through the normal REST endpoint. This keeps
authorization and response shaping in one place and tolerates dropped, duplicated,
or out-of-order WebSocket messages.

## Install

```ruby
# Gemfile
gem "belt-live"
```

```bash
bundle install
belt generate live
```

The generator installs a dedicated `live` Lambda, API Gateway v2 WebSocket API,
connection table, IAM policy, route declarations, and an optional browser helper.
Pass domain tables read by authorization through `--tables matches,seats`; current
conveyor-belt releases do not turn WebSocket route `tables:` metadata into IAM.
Local development has no socket server. Leave `VITE_LIVE_URL` empty and keep the
normal polling path as the fallback.

## Routes

```ruby
Belt.application.routes.draw do
  gateway :api do
    resources :matches
  end

  gateway :live, type: :websocket do
    on :connect,    to: "live_events#connect",    tables: [:live_connections]
    on :disconnect, to: "live_events#disconnect", tables: [:live_connections]
    on :default,    to: "live_events#unsupported"
    on :subscribe,  to: "live_events#subscribe",  tables: [:live_connections]
    on :ping,       to: "live_events#ping"
  end
end
```

`:connect`, `:disconnect`, and `:default` become API Gateway's `$connect`,
`$disconnect`, and `$default` route keys. Custom keys stay unchanged. WebSocket
gateways accept `on` routes only; REST gateways accept HTTP routes only.

`belt routes -f json` emits WebSocket entries under `websocket_routes`. Keeping
them separate prevents conveyor-belt versions that only understand REST from
trying to turn `ON $connect` into an HTTP route. `belt routes --namespace live`
still writes the complete Ruby manifest used by the live Lambda.

## Controller Actions

WebSocket controllers inherit from `Belt::LiveController`:

```ruby
class LiveEventsController < Belt::LiveController
  def subscribe
    authorize_channel!(frame.fetch("channel"))
    head :ok
  end
end
```

Actions receive the normal callbacks, `rescue_from`, and merged `params`, plus:

| Method | Value |
|--------|-------|
| `connection_id` | `requestContext.connectionId` |
| `route_key` | `requestContext.routeKey` |
| `query_params` | Raw connection query parameters |
| `frame` | Parsed JSON frame with snake-cased keys |

API Gateway chooses the route before Lambda runs. Belt routes using
`requestContext.routeKey`; it does not trust the frame's `action` field a second
time. `$connect` and `$disconnect` normally have no body and receive an empty
frame.

## Publishing

```ruby
Belt::Live.publish(
  channel: "match:#{match.id}",
  payload: { stateID: match.version },
  except: connection_id
)
```

Publishing is best effort. One failed connection never fails delivery to the
others and never fails the write that caused the publish. A 410 response removes
the stale connection. There is no durable delivery, replay, or ordering promise.
Keep a slow poll while connected and the old poll cadence while disconnected.

## Authentication

API Gateway WebSocket APIs can authorize only `$connect`. Browser WebSocket APIs
cannot set an `Authorization` header, so apps commonly use a short-lived query
credential. Do not log the query string or full connect event. `belt-live` requires
the app to configure connect and subscription authorization; channel names are
routing keys, not authorization.

A successful connection does not authorize every channel. Check each subscribe
request against the connection's subject or app credential. The push payload
should contain only enough information to trigger a REST fetch.

## AWS Limits

- Idle connections are closed after 10 minutes. The browser helper pings every
  five minutes and reconnects with backoff.
- A connection lasts at most two hours, so clients must reconnect and resubscribe.
- API Gateway frames are limited to 32 KB and messages to 128 KB. Belt-live keeps
  each nudge below one frame.
- `$disconnect` is best effort. Stale rows are also removed on 410 and expire by
  DynamoDB TTL.

## Frame Contract

Client to server:

```json
{"action":"subscribe","channel":"match:123"}
{"action":"ping"}
```

Server to client:

```json
{"channel":"match:123","payload":{"stateID":42}}
```

Unknown or unselectable actions reach `$default`. One connection stores one
active channel; subscribing to another replaces the previous channel.

## See Also

- `belt explain routing` — REST and WebSocket route declarations
- `belt explain lambda_handler` — event parsing and dispatch
- `belt explain controllers` — callbacks, params, and response helpers
- `belt explain plugins` — generator discovery and plugin layout
