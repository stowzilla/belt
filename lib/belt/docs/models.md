# Models

Belt uses **ActiveItem** as its ORM for DynamoDB. Models inherit from
`ActiveItem::Base` (typically via an `ApplicationRecord` base class).

## Basic Model

```ruby
class Post < ApplicationRecord
  attr_accessor :id, :user_id, :title, :body, :status, :created_at, :updated_at

  validates :title, presence: true
  validates :status, inclusion: { in: %w[draft published] }, allow_nil: true

  before_create { self.id ||= SecureRandom.uuid }
  before_save { self.updated_at = Time.now.iso8601 }
end
```

## Table Naming

Table names are derived from the environment:
`{APP_NAME}-{ENVIRONMENT}-{pluralized_model}`

Example: app "blog", environment "prod", model "Post" → `blog-prod-posts`

## Schema Definition

Define table structure in `infrastructure/schema.tf.rb`:

```ruby
Belt.application.schema.define do
  model :post do
    partition_key :id, :string
    global_secondary_index :UserIndex, partition_key: :user_id
    global_secondary_index :StatusIndex, partition_key: :status, sort_key: :created_at
  end
end
```

## CRUD Operations

### Create

```ruby
post = Post.create!(title: "Hello", body: "World", user_id: "u-123")
# or
post = Post.new(title: "Hello")
post.save!
```

### Read

```ruby
post = Post.find("post-id-123")           # by primary key
posts = Post.all                           # scan (use sparingly)
posts = Post.where(user_id: "u-123", index: "UserIndex")
post = Post.find_by(user_id: "u-123", index: "UserIndex")  # first match
```

### Update

```ruby
post = Post.find("post-id-123")
post.update(title: "New Title")
# or
post.title = "New Title"
post.save!
```

### Delete

```ruby
post = Post.find("post-id-123")
post.destroy
```

## Query Patterns

### Using Indexes

```ruby
# Query a GSI
Post.where(user_id: "u-123", index: "UserIndex")

# With sort key conditions
Post.where(
  status: "published",
  created_at: { gte: "2024-01-01" },
  index: "StatusIndex"
)
```

### Count and Existence

```ruby
Post.count                              # total items (scan)
Post.exists?("post-id-123")            # check by primary key
```

## Validations

ActiveItem supports ActiveModel-style validations:

```ruby
validates :title, presence: true
validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
validates :status, inclusion: { in: %w[active inactive] }
validates :age, numericality: { greater_than: 0 }
```

## Callbacks

```ruby
before_create  { self.id ||= SecureRandom.uuid }
before_save    { self.updated_at = Time.now.iso8601 }
after_create   { notify_subscribers }
before_destroy { cleanup_associations }
```

## Associations (Manual)

DynamoDB doesn't have joins. Model relationships manually:

```ruby
class Post < ApplicationRecord
  def comments
    Comment.where(post_id: id, index: "PostIndex")
  end

  def author
    User.find(user_id)
  end
end
```

## Transactions

```ruby
ActiveItem::Transaction.write do |tx|
  tx.put(post)
  tx.put(comment)
  tx.delete(draft)
end
```

## Generating Models

```bash
belt generate model post title:string body:text user_id:string
belt generate resource comment body:text author:string post_id:string
```

The resource generator creates model + controller + routes + schema entry.

## See Also

- `belt explain controllers` — using models in controllers
- `belt explain deployment` — how schema becomes infrastructure
- `belt explain queries` — advanced DynamoDB query patterns
