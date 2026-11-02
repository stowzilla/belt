/**
 * Post-build SEO/AEO step (runs as part of `npm run build`).
 *
 * Search and AI answer-engine crawlers mostly don't run JavaScript, so an SPA's
 * empty <div id="root"> tells them nothing. Using src/seo.js, this writes into dist/:
 *
 *   index.html, <path>.html  — each page in seo.pages rendered to HTML (via
 *                              dist-ssr/entry-server.js) with its own <title>,
 *                              description, canonical URL, Open Graph tags and JSON-LD
 *   robots.txt               — allows crawlers in indexable environments, `Disallow: /` elsewhere
 *   sitemap.xml              — every public page (needs a site URL)
 *   llms.txt                 — plain-text site summary for LLMs (https://llmstxt.org)
 *   .belt-pages.json         — S3 key → file map; `belt deploy frontend` uploads each page
 *                              to its extensionless key (/about → about.html) as text/html
 *
 * Environment:
 *   VITE_SITE_URL   canonical origin (belt deploy injects the frontend URL)
 *   BELT_ENV        environment being built (belt deploy injects it)
 *   SEO_INDEXABLE   "true"/"false" to override seo.indexableEnvironments
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import seo from '../src/seo.js'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const DIST = join(ROOT, 'dist')
const SSR_ENTRY = join(ROOT, 'dist-ssr', 'entry-server.js')

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

function robotsTxt() {
  if (!indexable) return 'User-agent: *\nDisallow: /\n'
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

async function main() {
  const indexFile = join(DIST, 'index.html')
  if (!existsSync(indexFile)) {
    console.error('dist/index.html not found — run `vite build` first')
    process.exit(1)
  }
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

  writeFileSync(join(DIST, '.belt-pages.json'), `${JSON.stringify(manifest, null, 2)}\n`)
  writeFileSync(join(DIST, 'robots.txt'), robotsTxt())
  writeFileSync(join(DIST, 'llms.txt'), llmsTxt())
  if (siteUrl) writeFileSync(join(DIST, 'sitemap.xml'), sitemapXml())

  if (!siteUrl) console.warn('⚠️  No site URL (VITE_SITE_URL or seo.siteUrl) — skipped canonical URLs and sitemap.xml')
  console.log(
    `SEO: prerendered ${pages.length} page(s), ${indexable ? 'indexable' : 'noindex'}` +
      `${process.env.BELT_ENV ? ` (${process.env.BELT_ENV})` : ''}`
  )
}

main()
