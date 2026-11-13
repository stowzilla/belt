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
invisible to them. Belt prerenders public pages as part of `belt deploy frontend`.
It's opt-in by manifest — the app owns the content, belt owns the mechanism:

```
src/seo.js             # the manifest: site name/description, public pages, private paths
src/entry-server.jsx   # optional: exports render(url) → HTML of <App /> at that URL
```

React frontends from `belt generate frontend react` ship both. Any other Vite
frontend opts in by adding `src/seo.js` (same shape as the React template's). A
frontend without one deploys exactly as before.

After `npm run build`, belt builds `src/entry-server.*` with `vite build --ssr`
(into `node_modules/.cache/belt-ssr`) and, for every entry in `seo.pages`, writes
real HTML into the build output with the page's rendered content, `<title>`, meta
description, canonical URL, Open Graph tags and JSON-LD. It also writes
`robots.txt`, `sitemap.xml` (from the same page list; needs a site URL) and
`llms.txt`. No SSR entry, or one that fails to build, still gets the tags,
sitemap and robots — just no prerendered content. Because it all lands in the
build output, every deploy's `s3 sync --delete` reproduces it; nothing is
uploaded out of band. Each page goes to its extensionless S3 key (`/pricing` →
`pricing`, served as `text/html`), and HTML and crawler files are served with
`no-cache`.

`robots.txt`: in indexable environments a project `public/robots.txt` is used
verbatim; otherwise belt generates `Allow: /`, a `Disallow:` per private path and
the `Sitemap:` line. Non-indexable environments always get `Disallow: /`.

Preview locally with `belt frontend prerender [--frontend NAME]` (builds, then
prerenders into `dist/`). Frontends scaffolded by belt 0.6.6–0.6.9 prerender inside
`npm run build` (`scripts/prerender.js`); belt sees their `dist/.belt-pages.json`
and skips its own step.

**When you add a public route, add it to `seo.pages`** with a specific title and a
one- or two-sentence description that says plainly what the page is. Login-gated
routes go in `privatePaths`. Components on public pages must render without
`window`/`document`/`localStorage` — touch those in `useEffect`. A page that throws
during prerender still gets its tags, but no content, and the deploy warns.
The SSR build uses the app's `vite.config.js`, so a library that touches the
browser at import time (Cognito/Amplify, analytics) can be stubbed with a plugin
that only applies when `isSsrBuild` is true — public pages render signed-out.

Only environments in `seo.indexableEnvironments` (default `['prod']`) are
indexable; every other environment and local builds ship `Disallow: /` and
`noindex`, so dev and ephemeral environments stay out of search results.
`belt deploy frontend` sets `BELT_ENV` and `VITE_SITE_URL` (the frontend URL) for
the build; set `SEO_INDEXABLE=true|false` to override.

After the first prod deploy, submit `https://<domain>/sitemap.xml` to Google
Search Console and Bing Webmaster Tools.

### Real 404s

A single-page app on S3 + CloudFront classically answers every path with
`index.html` and HTTP 200, because CloudFront can't tell which addresses the app
has. Crawlers and agents then can't tell a missing page from a real one. A
frontend with `src/seo.js` answers a real 404 instead:

- **A public page** (`seo.pages`) is served from its prerendered file.
- **A route of the app** is served `index.html`, as before.
- **Anything else** gets `404.html` with HTTP 404. That page is the app's own
  "not found" route (`<Route path="*">`) prerendered, with `noindex`.

You don't keep a route list. The prerender step reads the app's routes from its
`<Route path="/...">` declarations under `src/` (test files are skipped), adds
`seo.privatePaths` as prefixes, and writes them to `dist/.belt-routes.json`.
`belt deploy frontend` publishes that to a CloudFront KeyValueStore, and belt's
router function (`infrastructure/modules/app/belt_frontend_router.js`, on the
distribution's viewer-request and viewer-response events) reads it at the edge.
The deploy prints what it published:

```
SEO: 14 app route(s) and 6 page(s) answer; any other address is a 404
🧭 Published routes: 5 page(s), 14 app path(s); anything else answers 404
```

Belt only sees a route written as `<Route path="/literal/or/:param">`. A route
declared another way — a nested `<Route path="settings">`, a `createBrowserRouter`
config object, a path built at runtime — needs its prefix in `privatePaths`
(`'/account'` covers `/account` and everything under it). If one is missed,
nothing breaks in a browser: `404.html` loads the app, which routes to the real
page. Only the HTTP status is wrong, so check `dist/.belt-routes.json` after
adding a route in an unusual way.

A frontend that prerenders its own way (its `npm run build` writes the pages, as
the 0.6.6–0.6.9 templates did) still gets this: belt leaves its pages alone and
only adds the app routes and, if the build wrote none, `404.html`. Such a build
can write `dist/.belt-routes.json` itself to say where its pages are:
`{ "pages": ["/docs"], "objects": { "/": "/_pages/index.html", "/docs": "/_pages/docs.html" } }`.
`objects` is only needed for a page that isn't stored at its own extensionless
key.

It fails open. Until a deploy has published routes, or if the store can't be
read or written, every path behaves as it did before (index.html, 200). Paths
with a file extension are never rewritten. Customize the 404 page's metadata
with `seo.notFound: { title, description }`.

## Infrastructure

`belt setup frontend` (and `belt generate frontend`) writes S3 + CloudFront into
`infrastructure/modules/app/frontend.tf`. Additional named frontends get
`{name}_frontend.tf` with unique resource names and outputs
(`ops_frontend_bucket_name`, …). Extra frontends get a CloudFront URL only —
custom DNS stays on the default frontend unless you add records yourself.
The generated distribution includes the router function and KeyValueStore for
real 404s (above); `belt frontend router` rewrites `belt_frontend_router.js`
after a belt upgrade changes it.

CORS: each CloudFront domain is added to `frontend_urls` on the conveyor-belt
resource so SPA → API calls work.

## See Also

- `belt explain deployment` — how frontend deploy fits into `belt deploy`
- `belt explain generators` — `belt generate frontend` / views
- `belt explain structure` — where frontend directories live
