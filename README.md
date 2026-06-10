# Belt

A Rails-inspired framework for building serverless Ruby applications on AWS Lambda.

Belt bundles everything you need to go from zero to production:

- **BeltController** — callbacks, strong parameters, error handling, CORS
- **Belt::LambdaHandler** — Lambda entry point with observability, CORS preflight, error wrapping
- **Belt::ActionRouter** — request routing to controllers from route manifests
- **ActiveItem** — DynamoDB ORM (queries, validations, associations, transactions)
- **Lambda Loadout** — structured logging, CloudWatch metrics (EMF), error alerting
- **S3arch** — full-text search via SQLite FTS5, stored on S3, queried from Lambda

## Installation

Add to your Gemfile:

```ruby
gem "belt"
```

Then:

```bash
bundle install
```

## Quick Start

### 1. Project structure

```
my-app/
├── infrastructure/
│   ├── routes.tf.rb        # Belt provider route definitions
│   └── schema.tf.rb        # DynamoDB table schemas
├── lambda/
│   ├── controllers/
│   │   └── posts_controller.rb
│   ├── models/
│   │   └── post.rb
│   ├── lib/
│   │   └── routes.rb
│   └── api.rb              # Lambda entry point
├── Gemfile
└── Gemfile.lock
```

### 2. Define a model

```ruby
require "activeitem"

class Post < ActiveItem::Base
  self.primary_key = :id

  attr_accessor :id, :user_id, :title, :body, :created_at

  validates :title, presence: true
  before_create { self.id ||= SecureRandom.uuid }
end
```

### 3. Write a controller

```ruby
require "belt"

class PostsController < BeltController::Base
  before_action :authenticate!

  def index
    posts = Post.where(user_id: current_user_id, index: "UserIndex")
    success_response(posts.map(&:attributes))
  end

  def show
    post = Post.find(params["id"])
    success_response(post.attributes)
  end

  def create
    attrs = params.require(:post).permit(:title, :body).to_h
    post = Post.create!(attrs.merge(user_id: current_user_id))
    success_response(post.attributes, 201)
  end
end
```

### 4. Lambda entry point

Use `Belt::LambdaHandler` to get automatic observability, CORS preflight handling, and error wrapping:

```ruby
require "belt"

include Belt::LambdaHandler

ROUTER = Belt::ActionRouter.new(routes: Routes::API, namespace: "api")

def execute(path:, body:, event:)
  ROUTER.route(event: event, body: body)
end
```

That's it. `lambda_handler` is automatically your Lambda function handler. It:
- Initializes structured logging and CloudWatch metrics
- Handles OPTIONS preflight requests
- Parses JSON request bodies
- Catches unhandled errors and returns proper CORS-enabled error responses
- Calls your `execute` method for routing

### 5. Configure the Belt Terraform provider

The Belt Terraform provider (formerly Dispatcher) handles Lambda packaging, API Gateway routing, and IAM permissions.

Add the provider to your Terraform config:

```hcl
terraform {
  required_providers {
    belt = {
      source = "stowzilla/belt"
    }
  }
}
```

Define routes in `infrastructure/routes.tf.rb`:

```ruby
TerraDispatch.routes.draw do
  namespace :api do
    resources :posts, only: [:index, :show, :create]
  end
end
```

Define tables in `infrastructure/schema.tf.rb`:

```ruby
TerraDispatch.schema.define do
  model :post do
    partition_key :id, :string
    global_secondary_index :UserIndex, partition_key: :user_id
  end
end
```

Then deploy:

```bash
terraform init
terraform apply
```

The provider will:
- Package your Ruby code into Lambda functions
- Create API Gateway routes matching your DSL
- Generate IAM policies for DynamoDB table access
- Set up CloudWatch log groups

## BeltController Features

### Callbacks

```ruby
class AdminController < BeltController::Base
  before_action :authenticate!
  before_action :require_admin!, except: [:health]
  skip_before_action :authenticate!, only: [:health]
end
```

### Strong Parameters

```ruby
params.require(:user).permit(:name, :email, address: [:street, :city])
```

### Error Handling

```ruby
class ApiController < BeltController::Base
  rescue_from MyCustomError, with: :handle_custom

  private

  def handle_custom(exception, _context = {})
    error_response(exception.message, 422)
  end
end
```

### Response Helpers

```ruby
success_response({ id: "123", name: "Example" })       # 200 JSON with CORS
success_response({ id: "123" }, 201)                    # 201 Created
error_response("Not found", 404)                        # 404 JSON error
html_response("<h1>Hello</h1>")                         # 200 HTML with CORS
```

## Holsters (Belt's Engines)

Holsters are Belt's equivalent of Rails Engines. A holster lets a gem provide its own controllers, models, routes, and schema — all discovered automatically via convention.

### Creating a Holster

In your gem, subclass `Belt::Holster`:

```ruby
# lib/s3arch/holster.rb
module S3arch
  class Holster < Belt::Holster
  end
end
```

That's it. Belt discovers all `Holster` subclasses at boot. By convention, it expects:

```
your-gem/
├── infrastructure/
│   ├── routes.tf.rb      # Holster's route definitions
│   └── schema.tf.rb      # Holster's DynamoDB tables
└── lambda/
    ├── controllers/      # Holster's controllers
    └── models/           # Holster's models
```

No configuration needed if you follow the convention. Belt resolves paths relative to your gem's root (two directories up from the holster file).

### Customizing Paths

If your gem uses a different layout, override any path:

```ruby
module MyGem
  class Holster < Belt::Holster
    self.gem_root = File.expand_path("..", __dir__)
    self.controllers_path = File.join(gem_root, "app", "controllers")
  end
end
```

### How Belt Uses Holsters

- **Controllers**: `Belt::ActionRouter` searches holster controller paths automatically
- **Routes**: `Belt.all_routes_paths` collects all holster `routes.tf.rb` files for the Terraform provider
- **Schema**: `Belt.all_schema_paths` collects all holster `schema.tf.rb` files for the Terraform provider
- **Models**: `Belt.all_models_paths` collects all holster model directories

## Controller Discovery

Belt discovers controllers from the app's namespace module first, then searches `Belt.all_controller_paths` — which includes both app-defined paths and holster-provided paths. No registration needed.

## Belt::Observability

Belt provides global `Belt::Observability::Logger` and `Belt::Observability::Metrics` facades that are set automatically by `Belt::LambdaHandler`. Access them from anywhere:

```ruby
Belt::Observability::Logger.info("Something happened", user_id: "123")
Belt::Observability::Metrics.track_event("OrderCreated", model: "Order")
```

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `ENVIRONMENT` | Controls verbose error responses (`dev*`, `local`, `test`) |
| `BELT_METRICS_NAMESPACE` | CloudWatch metrics namespace (default: `Belt`) |
| `ACTION` | Service name for logging (falls back to function name) |
| `ERROR_NOTIFICATION_TOPIC_ARN` | SNS topic for error alerts |
| `CORS_ALLOWED_ORIGINS` | Comma-separated origins (overrides domain vars) |
| `CUSTOMER_APP_DOMAIN` | Primary app domain for CORS |
| `OPS_APP_DOMAIN` | Internal tools domain for CORS |

## License

MIT
