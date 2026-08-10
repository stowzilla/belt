# Console

`belt console` (alias: `belt c`) starts an interactive Ruby session with your
application fully loaded — models, configuration, AWS clients, everything.

## Basic Usage

```bash
belt console             # uses BELT_ENV or defaults to 'dev'
belt c prod              # specify environment
belt c dev01             # any environment name
```

## What Gets Loaded

1. `lambda/config/environment.rb` — your app's boot file (AWS setup, models, libs)
2. IRB starts with `reload!` available
3. `.irbrc` from project root (optional console customization)

## Runner Mode

Execute a command and exit (useful for scripts/CI):

```bash
belt c dev01 --run "Customer.first"
belt c prod --run "Post.count"
belt c dev01 --run "User.where(status: 'active', index: 'StatusIndex').count"
```

## Production Safety

When the environment is `prod`, Belt shows a confirmation prompt before
starting the console. This prevents accidentally running destructive commands
against production data.

## Common Tasks

```ruby
# Find a record
post = Post.find("post-id-123")

# Query with index
users = User.where(status: "active", index: "StatusIndex")

# Create a record
Post.create!(title: "Test", body: "Hello", user_id: "u-123")

# Count records
Order.count

# Reload code changes
reload!
```

## Environment Resolution

Priority order:
1. Explicit argument: `belt c prod`
2. `BELT_ENV` environment variable
3. Default: `dev`

## See Also

- `belt explain models` — ActiveItem query methods
- `belt explain structure` — where environment.rb lives
