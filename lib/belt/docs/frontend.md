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
VITE_COGNITO_CLIENT_ID: cognito_client_id
```

The default `frontend/` directory also accepts `.belt/frontend_env.yml` as a
fallback. See the existing env-map behavior: only mapped keys are written into
`.env`; missing terraform outputs warn and do not clobber local values.

## SEO and AI answer engines

Search crawlers and AI answer engines (ChatGPT, Claude, Perplexity, Google AI)
mostly don't run JavaScript, so an SPA that ships an empty `<div id="root">` is
invisible to them. React frontends from `belt generate frontend react` prerender
their public pages at build time:

```
src/seo.js             # site name/description, public pages, private paths
src/entry-server.jsx   # renders <App /> at a URL (build time only)
scripts/prerender.js   # runs at the end of `npm run build`
```

For every entry in `seo.pages`, `npm run build` writes real HTML with the page's
rendered content, `<title>`, meta description, canonical URL, Open Graph tags and
JSON-LD. It also writes `robots.txt`, `sitemap.xml` (needs a site URL) and
`llms.txt`. `belt deploy frontend` uploads each page to its extensionless S3 key
(`/pricing` → `pricing`, served as `text/html`) and serves HTML and crawler files
with `no-cache`.

**When you add a public route, add it to `seo.pages`** with a specific title and a
one- or two-sentence description that says plainly what the page is. Login-gated
routes go in `privatePaths`. Components on public pages must render without
`window`/`document`/`localStorage` — touch those in `useEffect`. A page that throws
during prerender still gets its tags, but no content, and the build warns.

Only environments in `seo.indexableEnvironments` (default `['prod']`) are
indexable; every other environment and local builds ship `Disallow: /` and
`noindex`, so dev and ephemeral environments stay out of search results.
`belt deploy frontend` sets `BELT_ENV` and `VITE_SITE_URL` (the frontend URL) for
the build; set `SEO_INDEXABLE=true|false` to override.

After the first prod deploy, submit `https://<domain>/sitemap.xml` to Google
Search Console and Bing Webmaster Tools.

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
