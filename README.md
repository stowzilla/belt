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

## Controller Registry

Gems can register controllers so Belt's `ActionRouter` discovers them without requiring a shim in the host app:

```ruby
# In your gem's initializer or boot file
Belt.register_controller("s3arch_dashboard", S3arch::Dashboard::S3archController)
```

The router checks the registry before falling back to namespace lookup. This lets gems ship their own controllers that inherit from `BeltController::Base`.

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
