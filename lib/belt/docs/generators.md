# Generators

Belt generators scaffold code and infrastructure for common patterns.
Run `belt generate --help` to see all available generators (built-in + plugins).

## Built-in Generators

### Resource (scaffold)

Creates model + controller + routes + schema entry:

```bash
belt generate resource post title:string body:text user_id:string status:string
belt g resource comment body:text author:string post_id:string
```

This is the most common generator — it sets up everything for a new REST endpoint.

### Model

Creates just the model file + schema entry:

```bash
belt generate model post title:string body:text user_id:string
belt g model payment amount:number currency:string
```

### Controller

Creates just the controller:

```bash
belt generate controller posts
belt g controller admin/users
```

### Environment

Scaffolds a new Terraform environment directory:

```bash
belt generate environment staging
belt g environment prod
```

### Frontend

Adds a frontend framework to the project:

```bash
belt generate frontend react
belt generate frontend vue
belt generate frontend svelte
belt generate frontend react --name ops --path ops-app
```

`--name` and `--path` scaffold an additional SPA and register it in
`config/frontends.yml`. See `belt explain frontend`.

### Views

Generates React pages for a resource's REST actions:

```bash
belt generate views post title:string body:text status:string
belt g views comment body:text author:string
belt g views bag --frontend ops
```

When the app has multiple frontends, pass `--frontend <name>` (or mark one
`default: true` in `config/frontends.yml`).

### Auth

Sets up Cognito authentication:

```bash
belt generate auth
belt g auth --provider cognito
```

## Field Types

When specifying fields, use these types:

| Type | DynamoDB Type | Notes |
|------|---------------|-------|
| `string` | S | Default if no type given |
| `text` | S | Same as string (semantic hint) |
| `number` | N | Numeric values |
| `boolean` | BOOL | True/false |
| `list` | L | Array values |
| `map` | M | Nested objects |

## Destroying Generated Code

Every generator has a matching destroy command:

```bash
belt destroy resource post
belt destroy model comment
belt destroy controller admin/users
belt destroy environment staging
belt destroy frontend
belt destroy frontend --frontend ops
belt destroy views post
```

### Non-interactive environment teardown

`belt destroy environment` is interactive by default: it prompts before running
`terraform destroy` and again before deleting local files. For CI pipelines and
agents that spin up ephemeral per-PR environments and tear them down on merge,
use `--yes`:

```bash
belt destroy environment pr-1234 --yes
```

`--yes` (alias `-y`) runs the whole teardown with zero prompts: it **always runs
`terraform destroy`** (when terraform state is present), then deletes the local
`infrastructure/<env>/` files.

Flag comparison:

| Flag | terraform destroy | Deletes local files | Prompts |
|------|-------------------|---------------------|---------|
| _(none)_ | Prompted | Prompted | Yes |
| `--yes` / `-y` | Always (if state exists) | Yes | No |
| `--force` / `-f` | **Skipped** (leaves cloud resources) | Yes | No |
| `--skip-terraform` | Never | Yes | Final delete only |

> `--force` is for the "just clean up my local files" case — it intentionally
> leaves cloud infrastructure running. Reach for `--yes` when you want the
> environment fully gone.

## Plugin Generators

Gems that follow the Belt plugin contract are auto-discovered:

```bash
belt generate messaging     # from belt-messaging gem
belt generate pay           # from belt-pay gem
belt generate --help        # lists all available generators
```

## Generator Workflow (Common Pattern)

```bash
# 1. Generate the resource
belt generate resource order item_id:string quantity:number total:number status:string

# 2. Generate DynamoDB table from schema
belt setup tables dev01

# 3. Deploy
belt deploy dev01
```

## See Also

- `belt explain models` — how generated models work
- `belt explain controllers` — how generated controllers work
- `belt explain routing` — how generated routes work
- `belt explain deployment` — deploying generated code
