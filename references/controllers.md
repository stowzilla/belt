# BeltController

`BeltController::Base` gives Rails-like callbacks, strong params, response
helpers, and error handling. Run `belt explain controllers` for canonical docs.

## Implicit responses

Instance variables assigned in an action become the JSON body by default:

```ruby
def index
  @posts = Post.all      # → { "posts": [ ... ] }
end
```

Explicit helpers always override implicit assigns.

## Callbacks

```ruby
before_action :authenticate_user!
before_action :require_admin!, except: [:health]
skip_before_action :authenticate_user!, only: [:health]
```

## Strong parameters

```ruby
params.require(:user).permit(:name, :email, address: [:street, :city])
```

## Response helpers

```ruby
success_response({ id: "123" })                 # 200 JSON + CORS
success_response({ id: "123" }, :created)       # 201 (symbol or int)
error_response("Not found", :not_found)         # 404 JSON error
error_response("Nope", :unprocessable_entity)   # 422
html_response("<h1>Hi</h1>")                     # 200 HTML + CORS
head :no_content                                 # 204 empty
response_status :created                         # 201 + implicit assigns
```

## Error handling

```ruby
rescue_from MyError, with: :handle_it

def handle_it(exception, _context = {})
  error_response(exception.message, 422)
end
```

## Default format (JSON vs HTML)

```ruby
# App-wide (lambda/config/environment.rb)
Belt.configure { |c| c.default_format = :json }   # default

# Per-controller
class PagesController < ApplicationController
  self.default_format = :html   # implicitly renders views/<controller>/<action>.html.erb
end
```

- `:json` (default): assigns → `success_response({ ... })`.
- `:html`: Belt implicitly renders the ERB template. Missing template raises
  `Belt::TemplateNotFound` (no silent JSON fallback).

## Controller discovery

No registration needed. Belt looks in the app namespace module first, then
`Belt.all_controller_paths`.
