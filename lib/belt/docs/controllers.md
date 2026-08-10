# Controllers

Belt controllers inherit from `BeltController::Base` and handle HTTP requests
dispatched by `Belt::ActionRouter`. They provide callbacks, strong parameters,
response helpers, and error handling — similar to Rails ActionController.

## Basic Controller

```ruby
module MyApp
  class PostsController < ApplicationController
    def index
      @posts = Post.all
    end

    def show
      @post = Post.find(params["id"])
    end

    def create
      attrs = params.require(:post).permit(:title, :body).to_h
      @post = Post.create!(attrs.merge(user_id: current_user_id))
      response_status :created
    end

    def destroy
      Post.find(params["id"]).destroy
      head :no_content
    end
  end
end
```

## Response Behavior

### Implicit Responses (default: JSON)

When an action sets instance variables and returns without calling a response
helper, Belt auto-serializes assigns into a JSON response:

```ruby
def index
  @posts = Post.all  # → { "posts": [...] }
end

def show
  @post = Post.find(params["id"])  # → { "post": {...} }
end
```

### Explicit Response Helpers

```ruby
success_response({ id: "123", name: "Example" })       # 200 JSON
success_response({ id: "123" }, :created)               # 201 JSON
error_response("Not found", :not_found)                 # 404 JSON
error_response("Nope", :unprocessable_entity)           # 422 JSON
html_response("<h1>Hello</h1>")                         # 200 HTML
head :no_content                                        # 204 empty
head :created                                           # 201 empty
```

### Non-200 with Implicit Assigns

```ruby
def create
  @post = Post.create!(...)
  response_status :created   # → 201 + { "post": {...} }
end
```

### Default Format

```ruby
# Global (in config/environment.rb)
Belt.configure do |config|
  config.default_format = :json   # or :html
end

# Per-controller
class PagesController < ApplicationController
  self.default_format = :html
end
```

- `:json` — assigns become JSON body
- `:html` — renders `views/<controller>/<action>.html.erb`

## Callbacks

```ruby
class ApplicationController < BeltController::Base
  before_action :authenticate!
  before_action :require_admin!, except: [:health]
  skip_before_action :authenticate!, only: [:health]
end
```

Callbacks run in definition order. `before_action` can halt the request by
calling a response helper (e.g., `error_response`).

## Strong Parameters

```ruby
params.require(:user).permit(:name, :email, address: [:street, :city])
```

- `params` — merged hash of path parameters + parsed JSON body
- `require(:key)` — raises if key missing
- `permit(:field1, :field2)` — whitelists allowed fields
- Nested: `permit(:name, address: [:street, :city])`

## Error Handling

```ruby
class ApplicationController < BeltController::Base
  rescue_from ActiveItem::RecordNotFound, with: :not_found
  rescue_from MyCustomError, with: :handle_custom

  private

  def not_found(exception, _context = {})
    error_response(exception.message, :not_found)
  end

  def handle_custom(exception, _context = {})
    error_response(exception.message, :unprocessable_entity)
  end
end
```

## Controller Discovery

Belt resolves controllers by:
1. Checking the app's namespace module (e.g., `MyApp::PostsController`)
2. Searching `Belt.all_controller_paths`

No manual registration required. Controllers are auto-discovered from the
`lambda/controllers/` directory.

## CORS

CORS headers are handled automatically by `Belt::LambdaHandler`. Controllers
don't need to set them manually. Configure allowed origins via environment
variables:

- `CORS_ALLOWED_ORIGINS` — comma-separated origins
- `CUSTOMER_APP_DOMAIN` — primary app domain
- `OPS_APP_DOMAIN` — internal tools domain

## See Also

- `belt explain routing` — how requests reach controllers
- `belt explain models` — ActiveItem ORM
- `belt explain parameters` — strong parameters in detail
