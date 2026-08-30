# frozen_string_literal: true

require 'fileutils'
require 'yaml'

module Belt
  module CLI
    # A named frontend application (SPA) in a Belt project.
    #
    # Belt apps historically used a single `frontend/` directory. Apps like
    # Stowzilla have several (customer `app/`, ops `ops-app/`, …). This object
    # is the per-frontend view of path, build output, and terraform outputs.
    class Frontend
      attr_reader :name, :dist, :bucket_output, :distribution_output,
                  :url_output, :cloudfront_domain_output
      attr_accessor :default, :path

      # -- keyword options from YAML config
      def initialize(name:, path:, dist: nil, bucket_output: nil, distribution_output: nil,
                     url_output: nil, cloudfront_domain_output: nil, default: false)
        @name = name.to_s
        @path = path.to_s.sub(%r{/\z}, '')
        @dist = dist
        @default = default
        @bucket_output = bucket_output || default_output('bucket_name')
        @distribution_output_explicit = present_output?(distribution_output)
        @distribution_output = @distribution_output_explicit ? distribution_output : default_output('distribution_id')
        @url_output = url_output || default_output('url')
        @cloudfront_domain_output = cloudfront_domain_output
      end

      def default?
        @default
      end

      def distribution_output_explicit?
        @distribution_output_explicit
      end

      def slug
        self.class.slug(name)
      end

      def self.slug(name)
        name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_|_\z/, '')
      end

      # Terraform resource name: `frontend` for the default, `{slug}_frontend` otherwise.
      def tf_name
        slug == 'frontend' ? 'frontend' : "#{slug}_frontend"
      end

      def output_prefix
        tf_name
      end

      def src_dir
        File.join(path, 'src')
      end

      def package_json
        File.join(path, 'package.json')
      end

      def app_jsx
        File.join(src_dir, 'App.jsx')
      end

      def exists?
        Dir.exist?(path) && File.file?(package_json)
      end

      # Build output directory. Explicit `dist:` wins; otherwise prefer `dist/`
      # then `build/` (CRA / some Vite configs) then default `dist`.
      def dist_dir
        return File.join(path, @dist) if @dist && !@dist.to_s.empty?

        %w[dist build].each do |dir|
          candidate = File.join(path, dir)
          return candidate if Dir.exist?(candidate)
        end

        File.join(path, 'dist')
      end

      def label
        name == 'frontend' ? 'frontend' : "frontend '#{name}'"
      end

      def yaml_lines
        lines = ["  #{name}:", "    path: #{path}"]
        lines << "    dist: #{dist}" if dist && !dist.to_s.empty?
        lines << '    default: true' if default?
        lines << "    bucket_output: #{bucket_output}" if bucket_output != inferred_output('bucket_name')
        if distribution_output != inferred_output('distribution_id')
          lines << "    distribution_output: #{distribution_output}"
        end
        lines << "    url_output: #{url_output}" if url_output != inferred_output('url')
        lines << "    cloudfront_domain_output: #{cloudfront_domain_output}" if cloudfront_domain_output
        lines
      end

      def inferred_output(suffix)
        slug == 'frontend' ? "frontend_#{suffix}" : "#{slug}_frontend_#{suffix}"
      end
      alias default_output inferred_output

      def present_output?(value)
        !(value.nil? || value.to_s.empty?)
      end
      private :inferred_output, :default_output, :present_output?
    end

    # Discovers and resolves frontends for CLI commands.
    #
    # Config (first match wins):
    #   config/frontends.yml
    #   config/frontends.yaml
    #   .belt/frontends.yml
    #   .belt/frontends.yaml
    #
    # If no config exists and `frontend/` is present, that directory is the
    # single implicit frontend (backwards compatible).
    #
    # Example:
    #
    #   frontends:
    #     customer:
    #       path: app
    #       dist: build
    #       default: true
    #       bucket_output: web_app_bucket_name
    #       url_output: web_app_url
    #       cloudfront_domain_output: web_app_cloudfront_domain
    #     ops:
    #       path: ops-app
    #       dist: build
    #       bucket_output: ops_app_bucket_name
    #       url_output: ops_app_url
    class FrontendRegistry
      CONFIG_CANDIDATES = [
        File.join('config', 'frontends.yml'),
        File.join('config', 'frontends.yaml'),
        File.join('.belt', 'frontends.yml'),
        File.join('.belt', 'frontends.yaml')
      ].freeze

      WRITE_PATH = File.join('config', 'frontends.yml')

      def self.find_config_path
        CONFIG_CANDIDATES.find { |path| File.file?(path) }
      end

      # Pull `--flag VALUE` or `--flag=VALUE` out of args, mutating the array.
      def self.extract_flag!(args, flag)
        i = 0
        while i < args.length
          arg = args[i]
          if arg == flag
            args.delete_at(i)
            return args.delete_at(i)
          elsif arg.start_with?("#{flag}=")
            args.delete_at(i)
            return arg.split('=', 2).last
          else
            i += 1
          end
        end
        nil
      end

      def self.load
        new
      end

      # Add (or update) a frontend and persist config/frontends.yml.
      def self.register!(name:, path:, default: nil)
        registry = new
        registry.add(name: name, path: path, default: default)
        registry.write!
      end

      def initialize
        @config_path = self.class.find_config_path
        @frontends = load_frontends
      end

      def all
        @frontends
      end

      def empty?
        @frontends.empty?
      end

      def existing
        @frontends.select(&:exists?)
      end

      def named(name)
        return nil if name.nil? || name.to_s.empty?

        key = name.to_s
        slug = Frontend.slug(key)
        @frontends.find { |fe| fe.name == key || fe.slug == slug }
      end

      # Default frontend: explicit `default: true`, otherwise the only one.
      def default
        @frontends.find(&:default?) || (@frontends.length == 1 ? @frontends.first : nil)
      end

      # Resolve a frontend for generate/server/auth. Aborts when ambiguous.
      def resolve!(name = nil)
        if name && !name.to_s.empty?
          fe = named(name)
          abort unknown_message(name) unless fe
          return fe
        end

        fe = default
        return fe if fe

        abort empty_message if @frontends.empty?

        abort multiple_message
      end

      def add(name:, path:, default: nil)
        name = name.to_s
        path = path.to_s.sub(%r{/\z}, '')
        existing = named(name)

        becomes_default = if !default.nil?
                            default
                          elsif existing
                            existing.default?
                          else
                            @frontends.empty?
                          end

        @frontends.each { |fe| fe.default = false } if becomes_default

        if existing
          existing.default = becomes_default
          existing.path = path
        else
          @frontends << Frontend.new(name: name, path: path, default: becomes_default)
        end

        named(name)
      end

      def write!
        dest = @config_path || WRITE_PATH
        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, dump_yaml)
        @config_path = dest
        dest
      end

      def unknown_message(name)
        "Error: Unknown frontend '#{name}'. #{known_suffix}"
      end

      def multiple_message
        "Error: Multiple frontends found (#{names.join(', ')}). " \
          'Specify one with --frontend <name>.'
      end

      def empty_message
        'Error: No frontend found. Run `belt generate frontend react` first, ' \
          'or add config/frontends.yml.'
      end

      def names
        @frontends.map(&:name)
      end

      private

      def load_frontends
        if @config_path
          parsed = parse_config(@config_path)
          return implicit_frontends if parsed.empty?

          parsed
        else
          implicit_frontends
        end
      end

      def implicit_frontends
        return [] unless Dir.exist?('frontend')

        [Frontend.new(name: 'frontend', path: 'frontend', default: true)]
      end

      def parse_config(path)
        raw = YAML.safe_load_file(path, aliases: false)
        return [] if raw.nil? || raw == false

        abort "Error: #{path} must be a YAML mapping of frontend names." unless raw.is_a?(Hash)

        entries = raw['frontends'].is_a?(Hash) ? raw['frontends'] : raw
        unless entries.is_a?(Hash)
          abort "Error: #{path} must map frontend names to settings " \
                '(e.g. frontends: { customer: { path: app } }).'
        end

        entries.filter_map do |name, settings|
          next if name.to_s == 'frontends' && settings.is_a?(Hash) && raw.key?('frontends')

          attrs = normalize_settings(name, settings)
          next unless attrs

          Frontend.new(**attrs)
        end
      rescue Psych::SyntaxError => e
        abort "Error: invalid YAML in #{path}: #{e.message}"
      end

      def normalize_settings(name, settings)
        case settings
        when Hash
          {
            name: name.to_s,
            path: (settings['path'] || settings[:path] || name).to_s,
            dist: settings['dist'] || settings[:dist],
            default: truthy?(settings['default'] || settings[:default]),
            bucket_output: settings['bucket_output'] || settings[:bucket_output],
            distribution_output: settings['distribution_output'] || settings[:distribution_output],
            url_output: settings['url_output'] || settings[:url_output],
            cloudfront_domain_output: settings['cloudfront_domain_output'] ||
              settings[:cloudfront_domain_output]
          }
        when String
          { name: name.to_s, path: settings }
        when nil
          { name: name.to_s, path: name.to_s }
        else
          abort "Error: frontend '#{name}' in #{@config_path} must be a mapping " \
                '(path:, dist:, …) or a directory path string.'
        end
      end

      def truthy?(value)
        value == true || value.to_s.downcase == 'true'
      end

      def dump_yaml
        lines = [
          '# Belt frontend registry',
          '# Used by `belt deploy frontend`, generators, and `belt server`.',
          '# See `belt explain frontend`.',
          '',
          'frontends:'
        ]
        @frontends.each { |fe| lines.concat(fe.yaml_lines) }
        "#{lines.join("\n")}\n"
      end

      def known_suffix
        if @frontends.empty?
          'No frontends are configured.'
        else
          "Known frontends: #{names.join(', ')}"
        end
      end
    end
  end
end
