# Belt

A Rails-inspired framework for building serverless Ruby applications on AWS Lambda.

Belt bundles everything you need to go from zero to production:

- **BeltController** — callbacks, strong parameters, error handling, CORS
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
│   └── models/
│       └── post.rb
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

### 4. Configure the Belt Terraform provider

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

### 5. Observability (Lambda Loadout)

Lambda Loadout is included automatically. Use it in your Lambda handler entry point:

```ruby
require "belt"
require "lambda_loadout"

LOGGER = LambdaLoadout::Logger.new(service: "my-app")
METRICS = LambdaLoadout::Metrics.new(namespace: "MyApp", service: "my-app")

def handler(event:, context:)
  LambdaLoadout.with_logging_and_metrics(LOGGER, METRICS, context, event: event) do
    # Your router dispatches to controllers here
  end
end
```

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

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `ENVIRONMENT` | Controls verbose error responses (`dev*`, `local`, `test`) |
| `CORS_ALLOWED_ORIGINS` | Comma-separated origins (overrides domain vars) |
| `CUSTOMER_APP_DOMAIN` | Primary app domain for CORS |
| `OPS_APP_DOMAIN` | Internal tools domain for CORS |

## License

MIT
