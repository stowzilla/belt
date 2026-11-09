# frozen_string_literal: true

require 'json'
require 'shellwords'

module Belt
  module CLI
    # Belt-owned SEO/AEO prerender step, run after a frontend's `npm run build`.
    #
    # Opt-in by manifest: a frontend with src/seo.js gets per-page HTML (title,
    # description, canonical, Open Graph, JSON-LD), robots.txt, sitemap.xml and
    # llms.txt written into its build output, so `aws s3 sync --delete`
    # reproduces them on every deploy. When src/entry-server.* exists it is built
    # with `vite build --ssr` and each page's markup is prerendered too. No
    # manifest → nothing happens.
    class FrontendPrerender
      SCRIPT = File.expand_path('../frontend/prerender.mjs', __dir__)
      MANIFESTS = %w[src/seo.js src/seo.mjs].freeze
      SSR_ENTRIES = %w[src/entry-server.jsx src/entry-server.tsx src/entry-server.js src/entry-server.ts].freeze
      # Inside node_modules so the SSR bundle resolves the app's dependencies and
      # existing apps don't grow an untracked build directory.
      SSR_OUT_DIR = 'node_modules/.cache/belt-ssr'
      PAGES_MANIFEST = '.belt-pages.json'

      def initialize(frontend, env: {})
        @frontend = frontend
        @env = env
      end

      def manifest
        @manifest ||= MANIFESTS.find { |file| File.file?(File.join(@frontend.path, file)) }
      end

      # Frontends scaffolded by belt 0.6.6–0.6.9 run their own scripts/prerender.js
      # inside `npm run build`; their output is already in dist.
      def prerendered_by_build?
        File.file?(File.join(@frontend.dist_dir, PAGES_MANIFEST))
      end

      # Returns true when it prerendered, false when the frontend didn't opt in.
      def run
        return false unless manifest

        if prerendered_by_build?
          puts '🔎 SEO: prerendered by the app build (scripts/prerender.js) — skipping belt prerender'
          return false
        end

        puts "🔎 SEO: prerendering pages from #{manifest}"
        ssr = build_ssr_bundle
        cmd = ['node', SCRIPT,
               '--manifest', File.expand_path(manifest, @frontend.path),
               '--dist', File.expand_path(@frontend.dist_dir),
               '--public', File.expand_path('public', @frontend.path)]
        cmd.push('--ssr', ssr) if ssr
        return true if system(@env, *cmd, chdir: @frontend.path)

        abort "\n✗ SEO prerender failed: #{cmd.shelljoin}"
      end

      private

      # Builds the SSR bundle and returns its entry path, or nil when there's no
      # entry or it doesn't build (typically a module touching window/document at
      # import time). Without it, pages still get their tags, sitemap and robots.
      def build_ssr_bundle
        entry = SSR_ENTRIES.find { |file| File.file?(File.join(@frontend.path, file)) }
        return nil unless entry

        out_dir = File.join(@frontend.path, SSR_OUT_DIR)
        ok = system(@env, 'npx', 'vite', 'build', '--ssr', entry, '--outDir', SSR_OUT_DIR, '--emptyOutDir',
                    '--logLevel', 'warn', chdir: @frontend.path)
        unless ok
          warn "⚠️  SSR build of #{entry} failed — pages get SEO tags but no prerendered content"
          return nil
        end

        # Vite emits ESM; make sure Node loads it as such whatever the app's package type.
        File.write(File.join(out_dir, 'package.json'), "#{JSON.generate(type: 'module')}\n")
        name = File.basename(entry, '.*')
        bundle = %w[.js .mjs].map { |ext| File.join(out_dir, "#{name}#{ext}") }.find { |f| File.file?(f) }
        bundle && File.expand_path(bundle)
      end
    end
  end
end
