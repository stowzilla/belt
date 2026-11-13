# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'

module Belt
  module CLI
    # Real 404s for a single-page frontend.
    #
    # CloudFront can't tell which addresses an SPA has, so the classic setup
    # answers every path with index.html and 200. Belt's router function
    # (lib/belt/frontend/router.js) fixes that at the edge, and this class keeps
    # it informed: after each deploy it publishes the routes the prerender step
    # wrote to <dist>/.belt-routes.json (from src/seo.js: `pages` and
    # `privatePaths`) into the CloudFront KeyValueStore the function reads.
    #
    # Nothing here is required for a deploy to work. No manifest, no router on the
    # distribution, or a failed publish all leave the site serving as it did.
    class FrontendRoutes
      ROUTER_SOURCE = File.expand_path('../frontend/router.js', __dir__)
      ROUTER_FILE = 'belt_frontend_router.js'
      MODULE_DIR = 'infrastructure/modules/app'
      MANIFEST = '.belt-routes.json'
      KEY = 'belt:routes'
      # A KeyValueStore value holds 1 KB.
      CHUNK_SIZE = 1000

      # Copies the router function next to the terraform that loads it with
      # file(). Returns the path when the file was written or refreshed.
      def self.install_router(module_dir = MODULE_DIR)
        dest = File.join(module_dir, ROUTER_FILE)
        source = File.read(ROUTER_SOURCE)
        return nil if File.file?(dest) && File.read(dest) == source

        FileUtils.mkdir_p(module_dir)
        File.write(dest, source)
        dest
      end

      # The KeyValueStore entries for a manifest: the chunk count under KEY and
      # the JSON split across KEY:0, KEY:1, ...
      def self.entries(manifest)
        routes = { 'app' => Array(manifest['app']), 'pages' => Array(manifest['pages']) }
        routes['objects'] = manifest['objects'] if manifest['objects'].is_a?(Hash) && manifest['objects'].any?
        json = JSON.generate(routes, ascii_only: true)
        chunks = json.scan(/.{1,#{CHUNK_SIZE}}/m)
        chunks.each_with_index.to_h { |chunk, i| ["#{KEY}:#{i}", chunk] }.merge(KEY => chunks.size.to_s)
      end

      def initialize(dist_dir:, distribution_id:)
        @dist_dir = dist_dir
        @distribution_id = distribution_id
      end

      def manifest
        path = File.join(@dist_dir, MANIFEST)
        return nil unless File.file?(path)

        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end

      # Returns :published, or the reason nothing was published.
      def publish
        routes = manifest
        return :no_manifest unless routes
        return :no_distribution unless @distribution_id

        store = key_value_store_arn
        unless store
          puts 'ℹ️  Unknown paths still answer 200: this CloudFront distribution has no belt router. ' \
               'See "Real 404s" in `belt explain seo`.'
          return :no_router
        end

        write(store, self.class.entries(routes))
        puts "🧭 Published routes: #{Array(routes['pages']).size} page(s), " \
             "#{Array(routes['app']).size} app path(s); anything else answers 404"
        :published
      rescue StandardError => e
        warn "⚠️  Could not publish routes (#{e.message.lines.first&.strip}). " \
             'The site keeps serving with the routes from the last deploy.'
        :failed
      end

      private

      # The store is whichever KeyValueStore the distribution's default-behavior
      # functions are associated with, so no extra terraform output is needed.
      def key_value_store_arn
        functions = aws_json('cloudfront', 'get-distribution-config', '--id', @distribution_id)
                    .dig('DistributionConfig', 'DefaultCacheBehavior', 'FunctionAssociations', 'Items') || []
        functions.each do |association|
          name = association['FunctionARN'].to_s.split('/').last
          next if name.to_s.empty?

          stores = aws_json('cloudfront', 'describe-function', '--name', name, '--stage', 'LIVE')
                   .dig('FunctionSummary', 'FunctionConfig', 'KeyValueStoreAssociations', 'Items') || []
          arn = stores.first&.fetch('KeyValueStoreARN', nil)
          return arn if arn
        end
        nil
      end

      # One atomic update: new entries in, chunks left over from a longer list out.
      def write(store, entries)
        etag = aws_json('cloudfront-keyvaluestore', 'describe-key-value-store', '--kvs-arn', store).fetch('ETag')
        existing = (aws_json('cloudfront-keyvaluestore', 'list-keys', '--kvs-arn', store)['Items'] || [])
                   .map { |item| item['Key'] }
        stale = existing.select { |key| key.start_with?(KEY) } - entries.keys

        cmd = ['cloudfront-keyvaluestore', 'update-keys', '--kvs-arn', store, '--if-match', etag,
               '--puts', JSON.generate(entries.map { |key, value| { 'Key' => key, 'Value' => value } })]
        cmd.push('--deletes', JSON.generate(stale.map { |key| { 'Key' => key } })) if stale.any?
        aws_json(*cmd)
      end

      def aws_json(*args)
        out, err, status = Open3.capture3('aws', *args, '--output', 'json')
        raise err.strip.empty? ? "aws #{args.first(2).join(' ')} failed" : err.strip unless status.success?

        out.strip.empty? ? {} : JSON.parse(out)
      end
    end
  end
end
