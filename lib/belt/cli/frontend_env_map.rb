# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'yaml'

module Belt
  module CLI
    # Resolves frontend env vars from a declarative map (env name → terraform output).
    #
    # Map file (optional), first match wins:
    #   frontend/env.yml
    #   frontend/env.yaml
    #   .belt/frontend_env.yml
    #   .belt/frontend_env.yaml
    #
    # Example:
    #   VITE_API_URL: api_url
    #   VITE_COGNITO_USER_POOL_ID: cognito_user_pool_id
    #   REACT_APP_API_URL: api_url
    #
    # No map → default { "VITE_API_URL" => "api_url" } (backwards compatible).
    class FrontendEnvMap
      MAP_CANDIDATES = [
        File.join('frontend', 'env.yml'),
        File.join('frontend', 'env.yaml'),
        File.join('.belt', 'frontend_env.yml'),
        File.join('.belt', 'frontend_env.yaml')
      ].freeze

      DEFAULT_MAP = { 'VITE_API_URL' => 'api_url' }.freeze

      DOTENV_PATH = File.join('frontend', '.env')

      attr_reader :env_name, :env_dir, :map_path, :map

      def initialize(env_name, env_dir: nil, map_path: nil)
        @env_name = env_name
        @env_dir = env_dir || File.join('infrastructure', env_name)
        @map_path = map_path || self.class.find_map_path
        @map = load_map
        @tf_cache = {}
      end

      def self.find_map_path
        MAP_CANDIDATES.find { |path| File.file?(path) }
      end

      # Hash of env_var => value suitable for process env (npm run build / vite).
      # Skips keys whose terraform output is missing.
      def process_env
        resolved = {}
        each_resolved do |env_key, value, _tf_output|
          resolved[env_key] = value if value
        end
        resolved
      end

      # Smart-merge mapped keys into frontend/.env.
      # - Only overwrites keys present in the map
      # - Preserves unknown keys, comments, and blank lines
      # - Missing TF output → warn, do not clobber an existing value
      def write_dotenv!(path: DOTENV_PATH)
        FileUtils.mkdir_p(File.dirname(path))

        existing_lines = File.file?(path) ? File.readlines(path, chomp: true) : []
        updates = {}
        missing = []

        each_resolved do |env_key, value, tf_output|
          if value
            updates[env_key] = value
          else
            missing << [env_key, tf_output]
          end
        end

        missing.each do |env_key, tf_output|
          puts "⚠️  terraform output '#{tf_output}' missing — leaving #{env_key} unchanged in #{path}"
        end

        written = {}
        new_lines = existing_lines.map do |line|
          key = dotenv_key(line)
          if key && updates.key?(key)
            written[key] = true
            format_dotenv_line(key, updates[key])
          else
            line
          end
        end

        updates.each do |key, value|
          next if written[key]

          new_lines << format_dotenv_line(key, value)
          written[key] = true
        end

        content = "#{new_lines.join("\n")}\n"
        File.write(path, content)

        {
          path: path,
          updated: written.keys.sort,
          missing: missing.map(&:first)
        }
      end

      def using_default_map?
        @map_path.nil?
      end

      private

      def load_map
        return DEFAULT_MAP.dup if @map_path.nil?

        raw = YAML.safe_load_file(@map_path, aliases: false)
        unless raw.is_a?(Hash) && raw.any?
          abort "Error: frontend env map #{@map_path} must be a non-empty YAML mapping " \
                '(e.g. VITE_API_URL: api_url).'
        end

        raw.each_with_object({}) do |(key, value), hash|
          k = key.to_s.strip
          v = value.to_s.strip
          next if k.empty? || v.empty?

          hash[k] = v
        end.tap do |parsed| # rubocop:disable Style/MultilineBlockChain
          abort "Error: frontend env map #{@map_path} has no valid entries." if parsed.empty?
        end
      rescue Psych::SyntaxError => e
        abort "Error: invalid YAML in #{@map_path}: #{e.message}"
      end

      def each_resolved
        map.each do |env_key, tf_output|
          yield env_key, fetch_tf_output(tf_output), tf_output
        end
      end

      def fetch_tf_output(name)
        return @tf_cache[name] if @tf_cache.key?(name)

        @tf_cache[name] = read_tf_output(name)
      end

      def read_tf_output(name)
        return nil unless Dir.exist?(@env_dir)

        output, status = Open3.capture2(
          'terraform', 'output', '-raw', name,
          chdir: @env_dir,
          err: File::NULL
        )
        return nil unless status.success?

        value = output.strip
        return nil if value.empty? || value == 'null'

        value
      rescue Errno::ENOENT
        nil
      end

      # Match KEY=value lines; ignore comments and export prefixes.
      def dotenv_key(line)
        return nil if line.strip.empty? || line.lstrip.start_with?('#')

        stripped = line.strip
        stripped = stripped.sub(/\Aexport\s+/, '')
        return nil unless stripped =~ /\A([A-Za-z_][A-Za-z0-9_]*)=/

        Regexp.last_match(1)
      end

      def format_dotenv_line(key, value)
        "#{key}=#{escape_dotenv_value(value)}"
      end

      def escape_dotenv_value(value)
        str = value.to_s
        return str if str.empty?
        return str unless str.match?(/[\s\#"'\\$`]/)

        %("#{str.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }}")
      end
    end
  end
end
