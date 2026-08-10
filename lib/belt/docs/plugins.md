# Plugins

Belt plugins are separate gems that extend the CLI and runtime. They're
discovered automatically — no registration file or initializer hook needed.

## Using a Plugin

```ruby
# Gemfile
gem "belt-messaging"
```

```bash
bundle install
belt generate messaging    # run the plugin's generator
belt destroy messaging     # remove what the generator created
```

## Available Plugins

| Gem | Purpose |
|-----|---------|
| `belt-messaging` | Two-way SMS via AWS End User Messaging |
| `belt-pay` | Stripe payments & subscriptions |

## Creating a Plugin

Scaffold a new plugin gem:

```bash
belt plugin new notifications
belt plugin new pay --path ~/Code --summary "Stripe payments for Belt"
```

This creates a gem with the correct structure and Belt integration points.

## Plugin Discovery Contract

Belt discovers plugins automatically when:

1. Gem is in the app's `Gemfile` and bundled
2. Gem has a file at `lib/belt/generators/<name>_generator.rb`
3. Class is `Belt::Generators::<Name>Generator`
4. Class implements `.run(args)` (required)

Optional: `.destroy(args)` and `.description` for destroy path and help text.

## Generator Checklist

A good plugin generator typically installs:

1. **Terraform module** → `infrastructure/modules/<name>/`
2. **Lambda config** → `config/lambda/<name>.yml`
3. **Lambda entrypoint** → `lambda/<name>.rb` using `Belt::LambdaHandler`
4. **Routes / schema** → inject into routes or schema when needed
5. **Optional overrides** → `--controllers` flag for app-local subclasses
6. **Destroy path** → removes everything the generator created
7. **Help text** → `.description` + `--help`

## Plugin Layout

```
belt-messaging/
├── belt-messaging.gemspec
├── lib/
│   ├── belt-messaging.rb              # require entrypoint
│   └── belt/
│       ├── messaging.rb               # Runtime API
│       ├── messaging/
│       │   ├── configuration.rb
│       │   ├── version.rb
│       │   ├── controllers/           # Default controllers
│       │   └── templates/             # ERB templates for generator
│       └── generators/
│           └── messaging_generator.rb # ← auto-discovered
└── spec/
```

## Development Workflow

Point a Belt app at your plugin during development:

```ruby
# In the app Gemfile
gem "belt-notifications", path: "../belt-notifications"
```

`belt deploy` detects `path:` gems and vendors them into `vendor/cache`
for Lambda packaging.

## See Also

- `belt explain generators` — built-in generators
- `belt plugin new --help` — scaffold options
