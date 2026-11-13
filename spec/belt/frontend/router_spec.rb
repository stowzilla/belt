# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/frontend_prerender'
require 'belt/cli/frontend_routes'

# Runs the real prerender script and the real CloudFront function (against a fake
# KeyValueStore) to check the whole path: routes read from the app, published as
# store entries, and resolved at the edge.
RSpec.describe 'frontend router (real 404s)' do
  before(:all) { skip 'node is not installed' unless system('node', '--version', out: File::NULL, err: File::NULL) }

  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  def create_file(path, content)
    full = File.join(tmpdir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def prerender!
    create_file('dist/index.html', <<~HTML)
      <html><head><title>App</title><meta name="description" content="x" /></head>
      <body><div id="root"></div><script type="module" src="/assets/index-abc.js"></script></body></html>
    HTML
    create_file('src/seo.js', <<~JS)
      export default {
        siteName: 'Acme',
        description: 'Acme does things.',
        pages: [{ path: '/', title: 'Acme' }, { path: '/pricing', title: 'Pricing' }, { path: '/docs/agents', title: 'Agents' }],
        privatePaths: ['/admin']
      }
    JS
    create_file('src/App.jsx', <<~JSX)
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/pricing" element={<Pricing />} />
        <Route path="/login" element={<Login />} />
        <Route path="/projects/:id" element={<Project />} />
        <Route path="/projects/:id/settings" element={<Settings />} />
        <Route path={'/files/*'} element={<Files />} />
        <Route path="*" element={<NotFound />} />
      </Routes>
    JSX
    create_file('src/App.test.jsx', '<Route path="/only-in-a-test" element={<X />} />')

    out, status = Open3.capture2e(
      'node', Belt::CLI::FrontendPrerender::SCRIPT,
      '--manifest', File.join(tmpdir, 'src/seo.js'), '--dist', File.join(tmpdir, 'dist'),
      '--src', File.join(tmpdir, 'src')
    )
    raise out unless status.success?

    JSON.parse(File.read(File.join(tmpdir, 'dist', Belt::CLI::FrontendRoutes::MANIFEST)))
  end

  # Runs the function for each [event type, uri] and returns the uri it serves
  # (viewer-request) or the status it answers (viewer-response).
  def run_router(entries, cases)
    source = File.read(Belt::CLI::FrontendRoutes::ROUTER_SOURCE).sub("import cf from 'cloudfront';", '')
    harness = <<~JS
      const store = #{JSON.generate(entries)};
      const cf = { kvs: () => ({ get: async (key) => { if (!(key in store)) throw new Error('KeyNotFound'); return store[key]; } }) };
      #{source}
      const results = [];
      for (const [eventType, uri, statusCode] of #{JSON.generate(cases)}) {
        const result = await handler({ context: { eventType }, request: { uri }, response: { statusCode: statusCode || 200 } });
        results.push(eventType === 'viewer-request' ? result.uri : result.statusCode);
      }
      console.log(JSON.stringify(results));
    JS
    out, err, status = Open3.capture3('node', '--input-type=module', '-e', harness)
    raise err unless status.success?

    JSON.parse(out)
  end

  it 'reads the app routes from its <Route> declarations, with no second list to keep' do
    routes = prerender!

    expect(routes['pages']).to eq(%w[/pricing /docs/agents])
    expect(routes['app']).to eq(%w[/admin/** /files/** /login /projects/* /projects/*/settings])
  end

  it 'writes a 404 page that is never indexed and still boots the app' do
    prerender!
    html = File.read(File.join(tmpdir, 'dist/404.html'))

    expect(html).to include('<title>Page not found | Acme</title>', '<meta name="robots" content="noindex" />')
    expect(html).to include('<h1>Page not found</h1>', '/assets/index-abc.js')
    expect(html).not_to include('rel="canonical"')
  end

  it 'serves pages and app routes, and answers 404 for everything else' do
    entries = Belt::CLI::FrontendRoutes.entries(prerender!)

    served = run_router(entries, [
                          ['viewer-request', '/'], ['viewer-request', '/pricing'], ['viewer-request', '/docs/agents/'],
                          ['viewer-request', '/login'], ['viewer-request', '/projects/42'],
                          ['viewer-request', '/projects/42/settings'], ['viewer-request', '/files/a/b/c'],
                          ['viewer-request', '/admin'], ['viewer-request', '/admin/users/7'],
                          ['viewer-request', '/assets/index-abc.js'], ['viewer-request', '/robots.txt'],
                          ['viewer-request', '/nonsense'], ['viewer-request', '/projects'],
                          ['viewer-request', '/projects/42/nope'], ['viewer-request', '/only-in-a-test']
                        ])
    expect(served).to eq(%w[/ /pricing /docs/agents /index.html /index.html /index.html /index.html /index.html
                            /index.html /assets/index-abc.js /robots.txt /404.html /404.html /404.html /404.html])

    statuses = run_router(entries, [
                            ['viewer-response', '/404.html'], ['viewer-response', '/nonsense'],
                            ['viewer-response', '/404.html', 304], ['viewer-response', '/pricing'],
                            ['viewer-response', '/index.html'], ['viewer-response', '/projects/42']
                          ])
    expect(statuses).to eq([404, 404, 304, 200, 200, 200])
  end

  it 'leaves every request alone until routes have been published' do
    served = run_router({}, [['viewer-request', '/nonsense'], ['viewer-request', '/projects/42']])
    statuses = run_router({}, [['viewer-response', '/nonsense']])

    expect(served).to eq(%w[/nonsense /projects/42])
    expect(statuses).to eq([200])
  end

  it 'reassembles a route list longer than one store value' do
    pages = (1..120).map { |i| "/guides/a-fairly-long-page-name-#{i}" }
    entries = Belt::CLI::FrontendRoutes.entries('pages' => pages, 'app' => ['/login'])

    expect(entries['belt:routes'].to_i).to be > 1
    expect(entries.values.map(&:bytesize).max).to be <= 1000
    expect(run_router(entries, [['viewer-request', pages.last], ['viewer-request', '/guides/nope']]))
      .to eq([pages.last, '/404.html'])
  end
end
