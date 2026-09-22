# Authoring Belt plugins

Belt stays lean; optional capabilities ship as **separate gems** that plug into
the CLI and runtime. Run `belt explain plugins` for canonical docs. Reference
implementations: `belt-messaging`, `belt-pay`.

## Discovery contract (GeneratorRegistry)

No central registry, no initializer. Belt discovers a generator when:

1. The gem is in the app's `Gemfile` and bundled.
2. It ships `lib/belt/generators/<name>_generator.rb`.
3. The class is `Belt::Generators::<Name>Generator`.
4. It implements `.run(args)` (required); optionally `.destroy(args)` and `.description`.

After `bundle install`, `belt generate <name>` and `belt destroy <name>` just work.

## Scaffold a plugin

```bash
belt plugin new notifications                       # → ./belt-notifications/
belt plugin new pay --path ~/Code --summary "Stripe payments for Belt"
```

Point an app at a local plugin while developing:

```ruby
# app Gemfile
gem "belt-notifications", path: "../belt-notifications"
```

`belt deploy` vendors `path:` gems into `vendor/cache` so conveyor-belt can
package them.

## Canonical layout

```
belt-messaging/
├── belt-messaging.gemspec
├── lib/
│   ├── belt-messaging.rb              # require entrypoint
│   └── belt/
│       ├── messaging.rb               # Belt::Messaging API
│       ├── messaging/{configuration,version}.rb
│       ├── messaging/controllers/     # default controllers (optional)
│       ├── messaging/templates/       # ERB for the generator
│       └── generators/messaging_generator.rb   # ← auto-discovered
└── spec/
```

**Runtime code stays in the gem.** Generators copy only what the host app must
own — Terraform modules, Lambda entrypoints, optional controller overrides.
Prefer gem defaults + `belt g <plugin> --controllers` over dumping everything
into the app.

## Generator checklist

1. Terraform module → `infrastructure/modules/<name>/`
2. Lambda config → `config/lambda/<name>.yml`
3. Lambda entrypoint → `lambda/<name>.rb` via `Belt::LambdaHandler`
4. Routes/schema injection when needed
5. Optional `--controllers` for app-local overrides
6. Matching `destroy` path
7. `.description` + `--help`
