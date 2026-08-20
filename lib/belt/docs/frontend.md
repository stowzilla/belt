# Frontends

Belt can host one or more JavaScript SPAs (React, Vue, or Svelte) next to the
Lambda API. A typical app has a single `frontend/` directory. Some apps — Stowzilla
is the example that drove this — have several independent SPAs (customer, ops,
partners) that share the same models and API.

## Single frontend (default)

```bash
belt new blog --frontend react
# or, in an existing app:
belt generate frontend react
```

That creates `frontend/`, S3 + CloudFront infrastructure, and wires CORS so the
SPA can call the API. No config file is required.

```bash
belt server                       # local Vite dev server
belt frontend env dev01           # write frontend/.env from terraform outputs
belt deploy frontend dev01        # npm ci → build → S3 sync → CloudFront invalidation
```

## Multiple frontends

Declare them in `config/frontends.yml` (or `.belt/frontends.yml`):

```yaml
frontends:
  customer:
    path: app
    dist: build
    default: true
    bucket_output: web_app_bucket_name
    url_output: web_app_url
    cloudfront_domain_output: web_app_cloudfront_domain
  ops:
    path: ops-app
    dist: build
    bucket_output: ops_app_bucket_name
    url_output: ops_app_url
    cloudfront_domain_output: ops_app_cloudfront_domain
```

`path` is the directory. `dist` is the build output (`dist` by default; belt
also auto-detects `build/` after `npm run build`). Terraform output names default
to `frontend_*` for the `frontend` app and `{name}_frontend_*` for others — override
them when existing infrastructure uses different names.

If terraform exports a CloudFront **domain** instead of a distribution ID, set
`cloudfront_domain_output` and skip `distribution_output`. Belt looks the ID up
via AWS and will not probe `{name}_frontend_distribution_id`.

```bash
belt frontend list
belt generate frontend react --name ops --path ops-app
belt generate views bag --frontend ops
belt generate scaffold order --frontend customer
belt server --frontend ops
belt frontend env dev01 --frontend customer
belt deploy frontend dev01                  # all configured frontends
belt deploy frontend dev01 --frontend ops   # just ops
```

If several frontends exist and you omit `--frontend`, generators and `belt server`
use the one marked `default: true`. If none is default, they ask you to pick.

`belt deploy frontend <env>` with no `--frontend` deploys every frontend that
has a `package.json`. Full `belt deploy <env>` does the same after terraform apply.

## Env maps

Each frontend can have its own `env.yml` mapping process env names to terraform
outputs:

```yaml
# app/env.yml
VITE_API_URL: api_url
VITE_COGNITO_USER_POOL_ID: cognito_user_pool_id
VITE_COGNITO_CLIENT_ID: cognito_user_pool_client_id
```

The default `frontend/` directory also accepts `.belt/frontend_env.yml` as a
fallback. See the existing env-map behavior: only mapped keys are written into
`.env`; missing terraform outputs warn and do not clobber local values.

## Infrastructure

`belt setup frontend` (and `belt generate frontend`) writes S3 + CloudFront into
`infrastructure/modules/app/frontend.tf`. Additional named frontends get
`{name}_frontend.tf` with unique resource names and outputs
(`ops_frontend_bucket_name`, …). Extra frontends get a CloudFront URL only —
custom DNS stays on the default frontend unless you add records yourself.

CORS: each CloudFront domain is added to `frontend_urls` on the conveyor-belt
resource so SPA → API calls work.

## See Also

- `belt explain deployment` — how frontend deploy fits into `belt deploy`
- `belt explain generators` — `belt generate frontend` / views
- `belt explain structure` — where frontend directories live
