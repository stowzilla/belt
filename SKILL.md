---
name: belt
license: MIT
description: >-
  Build, run, and deploy serverless Ruby apps on AWS Lambda with the Belt
  framework (Rails-inspired). Use when working in a Belt app or the belt gem:
  scaffolding apps/models/controllers/frontends, defining routes with the
  Belt routing DSL, writing BeltController actions, modeling DynamoDB data
  with ActiveItem, wiring Cognito auth, configuring the Lambda handler,
  running `belt` CLI commands (new, generate, deploy, console, routes, logs,
  server, setup, plugin, explain, db:copy/db:seed), Terraform via belt,
  backups, observability, or authoring Belt plugins. Triggers on "belt new",
  "belt deploy", "belt generate", "belt routes", "BeltController", "ActiveItem",
  "Belt::LambdaHandler", "belt console", "belt server", "conveyor-belt". Do NOT
  activate for physical belts, conveyor hardware, or unrelated Ruby web
  frameworks like Rails/Sinatra outside a Belt project.
metadata:
  author: stowzilla
  version: "0.1.0"
---

# Belt

Belt is a Rails-inspired framework for serverless Ruby on AWS Lambda. It ships a
runtime (`BeltController`, `Belt::LambdaHandler`, `Belt::ActionRouter`,
`Belt::Authentication`), a DynamoDB ORM (`ActiveItem`), logging/metrics
(`lambda_loadout`), a routing DSL consumed by the **conveyor-belt** Terraform
provider, and a `belt` CLI. Optional features (`belt-messaging`, `belt-pay`)
ship as separate plugin gems.

## First: orient yourself

Belt has an authoritative, in-repo docs system. **Use it before guessing.**

```bash
belt explain <topic>   # routing controllers models deployment generators
                       # lambda_handler observability console backups
                       # data_seeding plugins structure frontend authentication
belt --help            # full command list
belt routes            # list every endpoint (verb, path, controller#action)
belt doctor            # check deps + AWS config
```

- **Working in a Belt app?** Read the app's own `AGENTS.md` (scaffolded by `belt new`).
- **Working on the belt gem itself?** Read `AGENTS.md` + `README.md` at the gem root.
- The `belt explain` docs live at `lib/belt/docs/*.md` in the gem — the single
  source of truth for CLI behavior, controller lifecycle, and routing.

## Decision guide

| I want to… | Do this |
|---|---|
| Scaffold an app | `belt new <name> --frontend react` |
| Add a resource | `belt generate scaffold post title:string body:text` |
| See all routes | `belt routes` (add `-f json` for tooling) |
| Deploy to AWS | `belt deploy <env>` (`--auto` to skip prompt) |
| Poke at data live | `belt console <env>` |
| Run a local frontend | `belt server` (see references for env targeting) |
| Add Cognito auth | `belt generate auth` → `cognito_authenticatable` in a model |
| Build a plugin | `belt plugin new <name>` |
| Learn a concept | `belt explain <topic>` |

## Core patterns (memorize these)

**Controller** — assigns become the JSON body; explicit helpers win.

```ruby
class PostsController < BeltController::Base
  before_action :authenticate_user!

  def index
    @posts = Post.where(user_id: current_user.id, index: "UserIndex")
  end

  def create
    @post = Post.create!(params.require(:post).permit(:title, :body).to_h)
    response_status :created   # → 201 + { post: {...} }
  end

  def destroy
    Post.find(params["id"]).destroy
    head :no_content
  end
end
```

**Model** — ActiveItem over DynamoDB.

```ruby
class Post < ActiveItem::Base
  self.primary_key = :id
  attr_accessor :id, :user_id, :title, :body, :created_at
  validates :title, presence: true
  before_create { self.id ||= SecureRandom.uuid }
end
```

**Routes DSL** — `infrastructure/routes.tf.rb`. `gateway`/`function` pick the
Lambda; `namespace`/`scope` only affect paths + controller module.

```ruby
Belt.application.routes.draw do
  gateway :api, auth: :cognito do
    resources :posts do
      member     { post :publish }     # /posts/:post_id/publish
      collection { get  :recent }       # /posts/recent
    end
  end
end
```

**Lambda entry point** — `Belt::LambdaHandler` gives observability, CORS
preflight, JSON parsing, and error wrapping for free.

```ruby
require "belt"
include Belt::LambdaHandler
ROUTER = Belt::ActionRouter.new(routes: Routes::API, gateway: "api")

def execute(path:, body:, event:)
  ROUTER.route(event: event, body: body)
end
```

## Golden rules for agents

1. **`belt explain <topic>` before inventing behavior.** The docs are canonical.
2. **`namespace`/`scope` never change which Lambda serves a route** — only
   `gateway` and `function` do. Do not conflate them.
3. **Controllers need no registration.** Belt discovers them by convention.
4. **Runtime code stays in gems; generators copy only what the app must own.**
5. **Never commit secrets** (`.env`, AWS keys, real account IDs).
6. **`rubocop` + `rspec` must pass** before a PR on the belt gem.

## Deeper references

Load these only when the task needs them:

- [references/cli.md](references/cli.md) — every `belt` command, flags, env vars, Terraform shorthand
- [references/routing.md](references/routing.md) — full routing DSL, nested resources, request/response model inference
- [references/controllers.md](references/controllers.md) — callbacks, strong params, responses, error handling, formats
- [references/models-and-auth.md](references/models-and-auth.md) — ActiveItem + Cognito authentication
- [references/deploy-and-ops.md](references/deploy-and-ops.md) — deploy lifecycle, environments, backups, seeding, observability
- [references/plugins.md](references/plugins.md) — authoring Belt plugin gems and the GeneratorRegistry contract
