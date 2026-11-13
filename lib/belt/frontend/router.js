// Belt frontend router — a CloudFront Function (cloudfront-js-2.0), associated
// with the distribution's default behavior for both viewer-request and
// viewer-response. It makes an address with no page answer HTTP 404 instead of
// the app shell with 200, so crawlers and agents can tell a missing page from a
// real one.
//
// `belt deploy frontend` publishes the app's routes (src/seo.js) to the
// KeyValueStore associated with this function:
//
//   belt:routes     number of chunks
//   belt:routes:N   chunk N of the JSON { "app": [...], "pages": [...], "objects": {...} }
//                   (a KeyValueStore value holds 1 KB, so the JSON is split)
//
// `pages` are prerendered public pages, stored in S3 at their extensionless key
// unless `objects` names another object for that path ("/" included).
// `app` are patterns for the addresses the single-page app routes itself, read
// from its <Route path> declarations and seo.privatePaths: `*` is any one
// segment, a trailing `**` is anything from there on.
//
//   a page                → served from its own object
//   an app route          → /index.html
//   anything else         → /404.html, with status 404
//   a path with a file extension (/assets/x.js, /robots.txt) → untouched
//
// CloudFront's JavaScript engine is not Node: among other gaps it rejects `await`
// inside a call's arguments or a condition. Keep every await as its own
// `const x = await ...` statement (spec/belt/frontend/router_spec.rb checks).
//
// Until routes have been published, or if the store can't be read, every request
// passes through untouched and the distribution's custom error responses serve
// index.html, exactly as before this function existed.
import cf from 'cloudfront';

const NOT_FOUND = '/404.html';

async function loadRoutes() {
  try {
    const kvs = cf.kvs();
    const header = await kvs.get('belt:routes');
    const count = parseInt(header, 10);
    const reads = [];
    for (let i = 0; i < count; i++) reads.push(kvs.get('belt:routes:' + i));
    const chunks = await Promise.all(reads);
    return JSON.parse(chunks.join(''));
  } catch (error) {
    return null;
  }
}

function hasExtension(uri) {
  return uri.substring(uri.lastIndexOf('/') + 1).indexOf('.') !== -1;
}

// Where a request goes: null to leave it alone, or the object to serve.
async function resolve(uri) {
  if (hasExtension(uri)) return null;
  const path = uri.replace(/\/+$/, '');
  const routes = await loadRoutes();
  if (!routes) return null;

  const objects = routes.objects || {};
  if (path === '') return objects['/'] || null;
  if (routes.pages.indexOf(path) !== -1) return objects[path] || path;
  for (let i = 0; i < routes.app.length; i++) {
    if (matches(routes.app[i], path)) return '/index.html';
  }
  return NOT_FOUND;
}

function matches(pattern, path) {
  const want = pattern.split('/');
  const have = path.split('/');
  for (let i = 0; i < want.length; i++) {
    if (want[i] === '**') return true;
    if (i >= have.length) return false;
    if (want[i] !== '*' && want[i] !== have[i]) return false;
  }
  return want.length === have.length;
}

// An error thrown from a CloudFront Function is a 503 for the visitor, so
// anything unexpected leaves the request or response as it came.
async function handler(event) {
  const request = event.request;

  if (event.context.eventType === 'viewer-request') {
    try {
      const target = await resolve(request.uri);
      if (target) request.uri = target;
    } catch (error) {
      console.log('belt router: ' + error);
    }
    return request;
  }

  // viewer-response. The request here may carry the original address or the one
  // the viewer-request run rewrote, so both are checked. Only a 200 is changed:
  // a 304 revalidation of the 404 page has to stay a 304.
  const response = event.response;
  try {
    if (response.statusCode !== 200) return response;
    let target = request.uri;
    if (target !== NOT_FOUND) target = await resolve(request.uri);
    if (target === NOT_FOUND) {
      response.statusCode = 404;
      response.statusDescription = 'Not Found';
    }
  } catch (error) {
    console.log('belt router: ' + error);
  }
  return response;
}
