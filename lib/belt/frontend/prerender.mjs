/**
 * Belt's SEO/AEO prerender step. `belt deploy frontend` (and `belt frontend
 * prerender`) run it after `npm run build` for any frontend with a src/seo.js
 * manifest. The app owns the content (seo.js); belt owns the mechanism.
 *
 * Search and AI answer-engine crawlers mostly don't run JavaScript, so an SPA's
 * empty <div id="root"> tells them nothing. From the manifest this writes into dist/:
 *
 *   index.html, <path>.html  — each page in seo.pages rendered to HTML (via the SSR
 *                              bundle of src/entry-server.*, when there is one) with its
 *                              own <title>, description, canonical URL, Open Graph tags
 *                              and JSON-LD
 *   robots.txt               — allows crawlers in indexable environments, `Disallow: /`
 *                              elsewhere. A project public/robots.txt wins when indexable.
 *   sitemap.xml              — every public page (needs a site URL)
 *   llms.txt                 — plain-text site summary for LLMs (https://llmstxt.org)
 *   .belt-pages.json         — S3 key → file map; `belt deploy frontend` uploads each page
 *                              to its extensionless key (/about → about.html) as text/html
 *   404.html                 — what an address with no page gets, with HTTP 404: the app's
 *                              own "not found" route when it has one, never indexed
 *   .belt-routes.json        — the public pages, plus the app's own routes (every
 *                              <Route path="/..."> under --src and seo.privatePaths);
 *                              `belt deploy frontend` publishes them to CloudFront so it can
 *                              tell a real address from a missing one (see `belt explain
 *                              seo`, "Real 404s")
 *
 * With --routes-only (a frontend whose own build already prerendered its pages) nothing
 * above is touched except what real 404s need: .belt-routes.json gains the app's routes
 * (keeping any `pages`/`objects` the build wrote, else taking pages from .belt-pages.json),
 * and 404.html is written only if the build didn't write one.
 *
 * Usage: node prerender.mjs --manifest src/seo.js --dist dist [--ssr entry-server.js] [--public public] [--src src]
 *
 * Environment:
 *   VITE_SITE_URL   canonical origin (belt deploy injects the frontend URL)
 *   BELT_ENV        environment being built (belt deploy injects it)
 *   SEO_INDEXABLE   "true"/"false" to override seo.indexableEnvironments
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'

const { values: args } = parseArgs({
  options: {
    manifest: { type: 'string' },
    dist: { type: 'string' },
    ssr: { type: 'string' },
    public: { type: 'string' },
    src: { type: 'string' },
    'routes-only': { type: 'boolean' }
  }
})
if (!args.manifest || !args.dist) {
  console.error('Usage: node prerender.mjs --manifest src/seo.js --dist dist [--ssr entry-server.js] [--public public] [--src src]')
  process.exit(1)
}

const DIST = resolve(args.dist)
const SSR_ENTRY = args.ssr ? resolve(args.ssr) : null
const PROJECT_ROBOTS = args.public ? join(resolve(args.public), 'robots.txt') : null
const SRC = args.src ? resolve(args.src) : null
const seo = (await import(pathToFileURL(resolve(args.manifest)).href)).default

const siteUrl = (process.env.VITE_SITE_URL || seo.siteUrl || '').replace(/\/+$/, '')
const indexable = process.env.SEO_INDEXABLE
  ? process.env.SEO_INDEXABLE === 'true'
  : (seo.indexableEnvironments || ['prod']).includes(process.env.BELT_ENV)

const normalize = (path) => `/${path.replace(/^\/+|\/+$/g, '')}`
const privatePaths = (seo.privatePaths || []).map(normalize)
const isPrivate = (path) => privatePaths.some((p) => path === p || path.startsWith(`${p}/`))
const pages = (seo.pages || [])
  .map((page) => ({ ...page, path: normalize(page.path) }))
  .filter((page) => !isPrivate(page.path))

const escapeHtml = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
const absolute = (path) => `${siteUrl}${path === '/' ? '/' : path}`

async function loadRenderer() {
  if (!SSR_ENTRY) return null
  if (!existsSync(SSR_ENTRY)) {
    console.warn(`⚠️  ${SSR_ENTRY} not found — pages get SEO tags but no prerendered content`)
    return null
  }
  try {
    return (await import(pathToFileURL(SSR_ENTRY).href)).render
  } catch (error) {
    console.warn(`⚠️  Could not load the SSR bundle (${error.message}) — pages get SEO tags but no prerendered content`)
    return null
  }
}

function renderBody(render, path) {
  if (!render) return ''
  try {
    return render(path)
  } catch (error) {
    // Usually a component touching window/document/localStorage during render.
    // Move that into useEffect to get the content prerendered.
    console.warn(`⚠️  Prerender failed for ${path} (${error.message}) — serving SEO tags only`)
    return ''
  }
}

function jsonLd(page) {
  const data = page.jsonLd || {
    '@context': 'https://schema.org',
    '@type': page.path === '/' ? 'WebSite' : 'WebPage',
    name: page.title,
    description: page.description,
    ...(siteUrl ? { url: absolute(page.path) } : {})
  }
  return JSON.stringify(data).replace(/</g, '\\u003c')
}

function headTags(page) {
  const tags = []
  if (siteUrl) tags.push(`<link rel="canonical" href="${absolute(page.path)}" />`)
  if (!indexable) tags.push('<meta name="robots" content="noindex, nofollow" />')
  tags.push(
    `<meta property="og:type" content="website" />`,
    `<meta property="og:site_name" content="${escapeHtml(seo.siteName)}" />`,
    `<meta property="og:title" content="${escapeHtml(page.title)}" />`,
    `<meta property="og:description" content="${escapeHtml(page.description)}" />`
  )
  if (siteUrl) tags.push(`<meta property="og:url" content="${absolute(page.path)}" />`)
  if (page.image) tags.push(`<meta property="og:image" content="${escapeHtml(page.image)}" />`)
  tags.push(
    `<meta name="twitter:card" content="${page.image ? 'summary_large_image' : 'summary'}" />`,
    '<link rel="alternate" type="text/plain" href="/llms.txt" title="llms.txt" />',
    `<script type="application/ld+json">${jsonLd(page)}</script>`
  )
  return tags.map((tag) => `    ${tag}\n`).join('')
}

function pageHtml(template, page, body) {
  return template
    .replace(/<title>[\s\S]*?<\/title>/, () => `<title>${escapeHtml(page.title)}</title>`)
    .replace(/\s*<meta name="description"[^>]*>/, '')
    .replace(
      '</head>',
      () => `  <meta name="description" content="${escapeHtml(page.description)}" />\n${headTags(page)}  </head>`
    )
    .replace(
      '<div id="root"></div>',
      // data-prerendered tells main.jsx to hydrate rather than render fresh
      () => (body ? `<div id="root" data-prerendered="${escapeHtml(page.path)}">${body}</div>` : '<div id="root"></div>')
    )
}

// The addresses the single-page app routes itself, as patterns for belt's
// CloudFront router: `*` is one segment, a trailing `**` is the rest. They come
// from the app's own <Route path="/..."> declarations, so adding a route needs no
// second list, plus seo.privatePaths for anything declared another way (nested
// relative routes, a router config object, a path built at runtime).
const ROUTE_PATH = /<Route\b[^>]*?\bpath=\{?["'`](\/[^"'`]*)["'`]/g
const SOURCE_FILE = /\.(jsx?|tsx?)$/
const TEST_FILE = /\.(test|spec)\.|__tests__/

function sourceFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return entry.name === 'node_modules' ? [] : sourceFiles(path)
    return SOURCE_FILE.test(entry.name) && !TEST_FILE.test(path) ? [path] : []
  })
}

function routePattern(path) {
  const segments = []
  for (const segment of normalize(path).split('/').slice(1)) {
    if (segment === '*' || segment.endsWith('?')) return ['', ...segments, '**'].join('/')
    segments.push(segment.startsWith(':') ? '*' : segment)
  }
  return ['', ...segments].join('/')
}

function appRoutes(pagePaths) {
  const declared = SRC && existsSync(SRC)
    ? sourceFiles(SRC).flatMap((file) => [...readFileSync(file, 'utf-8').matchAll(ROUTE_PATH)].map((match) => match[1]))
    : []
  const patterns = [...declared.map(routePattern), ...privatePaths.map((path) => `${path}/**`)]
  return [...new Set(patterns)].filter((pattern) => pattern !== '/' && !pagePaths.includes(pattern)).sort()
}

// Served for every address that is neither a page nor an app route. It keeps the
// app's scripts, so a route belt couldn't see still boots the app in a browser.
const NOT_FOUND_PATH = '/404'

function notFoundHtml(template, body) {
  const title = seo.notFound?.title || `Page not found | ${seo.siteName}`
  const description = seo.notFound?.description || `There is no page at this address on ${seo.siteName}.`
  const fallback = `<main><h1>Page not found</h1><p>${escapeHtml(description)}</p><p><a href="/">${escapeHtml(seo.siteName)}</a></p></main>`
  return template
    .replace(/<title>[\s\S]*?<\/title>/, () => `<title>${escapeHtml(title)}</title>`)
    .replace(/\s*<meta name="description"[^>]*>/, '')
    .replace(
      '</head>',
      () =>
        `  <meta name="description" content="${escapeHtml(description)}" />\n` +
        '    <meta name="robots" content="noindex" />\n  </head>'
    )
    .replace(
      '<div id="root"></div>',
      () => (body ? `<div id="root" data-prerendered="${NOT_FOUND_PATH}">${body}</div>` : `<div id="root">${fallback}</div>`)
    )
}

function robotsTxt() {
  if (!indexable) return 'User-agent: *\nDisallow: /\n'
  if (PROJECT_ROBOTS && existsSync(PROJECT_ROBOTS)) return readFileSync(PROJECT_ROBOTS, 'utf-8')
  const lines = ['User-agent: *', 'Allow: /', ...privatePaths.map((p) => `Disallow: ${p}`)]
  if (siteUrl) lines.push('', `Sitemap: ${siteUrl}/sitemap.xml`)
  return `${lines.join('\n')}\n`
}

function sitemapXml() {
  const urls = pages.map((page) => `  <url><loc>${escapeHtml(absolute(page.path))}</loc></url>`).join('\n')
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`
}

function llmsTxt() {
  const lines = [`# ${seo.siteName}`, '', `> ${seo.description}`, '', '## Pages', '']
  for (const page of pages) lines.push(`- [${page.title}](${absolute(page.path)}): ${page.description}`)
  return `${lines.join('\n')}\n`
}

const readJson = (file) => (existsSync(file) ? JSON.parse(readFileSync(file, 'utf-8')) : null)

// The app's build prerendered its own pages. Fill in what real 404s still need.
function completeRoutes(indexFile) {
  const routesFile = join(DIST, '.belt-routes.json')
  const built = readJson(routesFile) || {}
  const pagePaths = built.pages || Object.keys(readJson(join(DIST, '.belt-pages.json')) || {}).map(normalize)
  const routes = { ...built, pages: pagePaths, app: appRoutes(pagePaths) }

  writeFileSync(routesFile, `${JSON.stringify(routes, null, 2)}\n`)
  if (!existsSync(join(DIST, '404.html'))) {
    writeFileSync(join(DIST, '404.html'), notFoundHtml(readFileSync(indexFile, 'utf-8'), ''))
  }
  console.log(`SEO: ${routes.app.length} app route(s) and ${pagePaths.length + 1} page(s) answer; any other address is a 404`)
}

async function main() {
  const indexFile = join(DIST, 'index.html')
  if (!existsSync(indexFile)) {
    console.error(`${indexFile} not found — run \`vite build\` first`)
    process.exit(1)
  }
  if (args['routes-only']) return completeRoutes(indexFile)
  if (!pages.some((page) => page.path === '/')) pages.unshift({ path: '/', title: seo.siteName })
  for (const page of pages) {
    page.title ||= seo.siteName
    page.description ||= seo.description
  }

  const template = readFileSync(indexFile, 'utf-8')
  const render = await loadRenderer()
  const manifest = {}

  for (const page of pages) {
    const html = pageHtml(template, page, renderBody(render, page.path))
    const key = page.path.slice(1)
    const file = key ? `${key}.html` : 'index.html'
    mkdirSync(dirname(join(DIST, file)), { recursive: true })
    writeFileSync(join(DIST, file), html)
    if (key) manifest[key] = file
  }

  writeFileSync(join(DIST, '404.html'), notFoundHtml(template, renderBody(render, NOT_FOUND_PATH)))
  const pagePaths = pages.map((page) => page.path).filter((path) => path !== '/')
  const routes = { pages: pagePaths, app: appRoutes(pagePaths) }

  writeFileSync(join(DIST, '.belt-pages.json'), `${JSON.stringify(manifest, null, 2)}\n`)
  writeFileSync(join(DIST, '.belt-routes.json'), `${JSON.stringify(routes, null, 2)}\n`)
  writeFileSync(join(DIST, 'robots.txt'), robotsTxt())
  writeFileSync(join(DIST, 'llms.txt'), llmsTxt())
  if (siteUrl) writeFileSync(join(DIST, 'sitemap.xml'), sitemapXml())

  if (PROJECT_ROBOTS && indexable && existsSync(PROJECT_ROBOTS)) console.log('SEO: robots.txt from public/robots.txt')
  if (!siteUrl) console.warn('⚠️  No site URL (VITE_SITE_URL or seo.siteUrl) — skipped canonical URLs and sitemap.xml')
  console.log(`SEO: ${routes.app.length} app route(s) and ${pagePaths.length + 1} page(s) answer; any other address is a 404`)
  console.log(
    `SEO: prerendered ${pages.length} page(s), ${indexable ? 'indexable' : 'noindex'}` +
      `${process.env.BELT_ENV ? ` (${process.env.BELT_ENV})` : ''}`
  )
}

await main()
