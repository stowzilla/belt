# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/frontend_registry'
require 'belt/cli/frontend_prerender'

RSpec.describe Belt::CLI::FrontendPrerender do
  let(:tmpdir) { Dir.mktmpdir }
  let(:frontend) { Belt::CLI::Frontend.new(name: 'frontend', path: tmpdir) }
  let(:prerender) { described_class.new(frontend, env: { 'BELT_ENV' => 'prod' }) }

  after { FileUtils.rm_rf(tmpdir) }

  def create_file(path, content = '')
    full = File.join(tmpdir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  it 'ships the prerender script in the gem' do
    expect(File).to exist(described_class::SCRIPT)
  end

  context 'without a src/seo.js manifest' do
    it 'does nothing' do
      create_file('dist/index.html', '<div id="root"></div>')
      expect(prerender).not_to receive(:system)

      expect(prerender.run).to be(false)
    end
  end

  context 'when the app build already prerendered (0.6.6–0.6.9 templates)' do
    it 'skips its own step' do
      create_file('src/seo.js', 'export default {}')
      create_file('dist/.belt-pages.json', '{}')
      expect(prerender).not_to receive(:system)

      expect { expect(prerender.run).to be(false) }.to output(/prerendered by the app build/).to_stdout
    end
  end

  context 'with a manifest' do
    before do
      create_file('src/seo.js', 'export default {}')
      create_file('dist/index.html', '<div id="root"></div>')
    end

    it 'runs the gem script against the manifest and build output' do
      expect(prerender).to receive(:system) do |env, *cmd, **opts|
        expect(env).to eq('BELT_ENV' => 'prod')
        expect(cmd.first(2)).to eq(['node', described_class::SCRIPT])
        expect(cmd).to include('--manifest', File.join(tmpdir, 'src/seo.js'), '--dist', File.join(tmpdir, 'dist'))
        expect(cmd).not_to include('--ssr')
        expect(opts).to eq(chdir: tmpdir)
        true
      end

      expect { expect(prerender.run).to be(true) }.to output(%r{prerendering pages from src/seo.js}).to_stdout
    end

    it 'builds the SSR entry and passes the bundle' do
      create_file('src/entry-server.jsx', 'export function render() {}')
      calls = []
      allow(prerender).to receive(:system) do |_env, *cmd, **_opts|
        calls << cmd
        create_file("#{described_class::SSR_OUT_DIR}/entry-server.js") if cmd.first == 'npx'
        true
      end

      expect { prerender.run }.to output.to_stdout
      expect(calls.first).to start_with('npx', 'vite', 'build', '--ssr', 'src/entry-server.jsx')
      expect(calls.last).to include('--ssr', File.join(tmpdir, described_class::SSR_OUT_DIR, 'entry-server.js'))
    end

    it 'prerenders without content when the SSR build fails' do
      create_file('src/entry-server.jsx', 'export function render() {}')
      allow(prerender).to receive(:system) { |_env, *cmd, **_opts| cmd.first != 'npx' }

      expect { prerender.run }.to output.to_stdout.and output(%r{SSR build of src/entry-server.jsx failed}).to_stderr
    end
  end
end
