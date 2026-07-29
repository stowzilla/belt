# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rubygems/package'

module Belt
  module CLI
    # Turns Gemfile `path:` gems into real `.gem` files in vendor/cache and
    # rewrites the Gemfile/lock so Docker `bundle install` produces a normal
    # gem install (with specifications/). Required for Lambda bare `require`
    # without bundler/setup.
    #
    # Only mutates files under +build_dir+ — never the app's real Gemfile.
    class PathGemMaterializer
      PathSource = Struct.new(:remote, :gems, keyword_init: true)
      PathGem = Struct.new(:name, :version, keyword_init: true)

      def self.materialize!(build_dir, project_root:)
        new(build_dir, project_root: project_root).materialize!
      end

      def initialize(build_dir, project_root:)
        @build_dir = build_dir
        @project_root = project_root
        @gemfile = File.join(build_dir, 'Gemfile')
        @lockfile = File.join(build_dir, 'Gemfile.lock')
      end

      # @return [Array<String>] names of gems materialized (empty if none)
      def materialize!
        return [] unless File.exist?(@gemfile) && File.exist?(@lockfile)

        sources = parse_path_sources(File.read(@lockfile))
        return [] if sources.empty?

        cache_dir = File.join(@build_dir, 'vendor', 'cache')
        FileUtils.mkdir_p(cache_dir)

        materialized = []
        sources.each do |source|
          source_path = resolve_remote(source.remote)
          unless Dir.exist?(source_path)
            abort "✗ path gem source missing: #{source.remote} (resolved #{source_path})"
          end

          source.gems.each do |gem|
            gem_file = build_gem(source_path, gem)
            dest = File.join(cache_dir, File.basename(gem_file))
            FileUtils.cp(gem_file, dest)
            FileUtils.rm_f(gem_file)
            rewrite_gemfile_path_to_version!(gem.name, gem.version)
            materialized << gem.name
          end
        end

        return [] if materialized.empty?

        relock!(materialized)
        materialized
      end

      private

      def parse_path_sources(lockfile_content)
        sources = []
        lockfile_content.scan(/^PATH\n  remote: (.+)\n  specs:\n((?:    .+\n)*)/) do |remote, specs_block|
          gems = []
          specs_block.each_line do |line|
            next unless line.match?(/^    \S/)
            next if line.start_with?('      ') # dependency lines are deeper

            match = line.match(/^    (\S+)\s+\(([^)]+)\)/)
            gems << PathGem.new(name: match[1], version: match[2]) if match
          end
          sources << PathSource.new(remote: remote.strip, gems: gems) if gems.any?
        end
        sources
      end

      def resolve_remote(remote)
        return remote if remote.start_with?('/')

        File.expand_path(remote, @project_root)
      end

      def build_gem(source_path, gem)
        gemspec = find_gemspec(source_path, gem.name)
        abort "✗ No gemspec for path gem #{gem.name} under #{source_path}" unless gemspec

        Dir.chdir(source_path) do
          spec = Gem::Specification.load(File.basename(gemspec))
          abort "✗ Failed to load #{gemspec}" unless spec

          if spec.version.to_s != gem.version
            abort "✗ path gem #{gem.name} version mismatch: gemspec #{spec.version}, lock #{gem.version}"
          end

          # Gem::Package.build writes the .gem into cwd
          built = Gem::Package.build(spec)
          File.expand_path(built)
        end
      end

      def find_gemspec(source_path, gem_name)
        preferred = File.join(source_path, "#{gem_name}.gemspec")
        return preferred if File.exist?(preferred)

        Dir.glob(File.join(source_path, '*.gemspec')).first
      end

      def rewrite_gemfile_path_to_version!(name, version)
        content = File.read(@gemfile)
        new_content = content.lines.map { |line| convert_path_line(line, name, version) }.join
        if new_content == content
          abort "✗ Could not rewrite path: for gem #{name.inspect} in build Gemfile"
        end
        File.write(@gemfile, new_content)
      end

      # Converts `gem 'name', path: '...'` (and variants with other kwargs) into
      # a version-pinned line. Leaves non-matching lines alone.
      def convert_path_line(line, name, version)
        return line unless line.match?(/gem\s+(['"])#{Regexp.escape(name)}\1/)
        return line unless line.match?(/\bpath:\s*/)

        quote = line[/gem\s+(['"])/, 1] || "'"
        cleaned = line.sub(/,?\s*path:\s*['"][^'"]+['"]/, '')
        cleaned.sub(/gem\s+(['"])#{Regexp.escape(name)}\1/) do
          "gem #{$1}#{name}#{$1}, #{$1}#{version}#{$1}"
        end
      end

      def relock!(gem_names)
        Dir.chdir(@build_dir) do
          # vendor/cache has the built .gem — Bundler resolves the unpublished version
          output, status = Open3.capture2e('bundle', 'lock', '--update', *gem_names)
          return if status.success?

          abort "✗ Failed to re-lock after materializing path gems (#{gem_names.join(', ')}):\n#{output}"
        end
      end
    end
  end
end
