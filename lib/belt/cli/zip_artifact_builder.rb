# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'

module Belt
  module CLI
    # Builds zip files that Terraform `filebase64sha256(...)` / `filename = "...zip"`
    # references before plan/apply. Conveyor Belt packages Ruby lambdas itself;
    # sidecar functions (Node image processors, Cognito triggers, …) are plain
    # `aws_lambda_function` resources that expect a zip on disk at plan time.
    #
    # Node packages (`package.json`) are installed in Docker on linux/amd64 so
    # native addons like `sharp` match Lambda. Plain JS directories are zipped
    # as-is. Existing zips are reused when a source hash still matches.
    class ZipArtifactBuilder
      NODE_DOCKER_IMAGE = 'public.ecr.aws/lambda/nodejs:20-x86_64'
      ZIP_REF = /(?:filebase64sha256\(\s*|filename\s*=\s*)["']([^"']+\.zip)["']/

      def self.build!(project_root: Dir.pwd, infra_dir: 'infrastructure')
        new(project_root: project_root, infra_dir: infra_dir).build!
      end

      def initialize(project_root:, infra_dir:)
        @project_root = File.expand_path(project_root)
        @infra_dir = File.expand_path(infra_dir, @project_root)
      end

      Artifact = Struct.new(:zip_path, :source_dir, keyword_init: true)

      def build!
        artifacts = discover_artifacts
        return if artifacts.empty?

        artifacts.each { |artifact| ensure_zip!(artifact) }
      end

      private

      def discover_artifacts
        return [] unless Dir.exist?(@infra_dir)

        zips = []
        tf_files.each do |tf_file|
          File.read(tf_file).scan(ZIP_REF).flatten.each do |raw_path|
            zip_path = resolve_zip_path(tf_file, raw_path)
            next unless zip_path

            zips << zip_path
          end
        end

        zips.uniq.filter_map do |zip_path|
          source_dir = File.dirname(zip_path)
          next unless Dir.exist?(source_dir)

          Artifact.new(zip_path: zip_path, source_dir: source_dir)
        end
      end

      def tf_files
        Dir.glob(File.join(@infra_dir, '**/*.tf')).reject { |path| path.include?('/.terraform/') }
      end

      # Skip interpolations other than ${path.module} — we can't resolve those
      # without running terraform.
      def resolve_zip_path(tf_file, raw_path)
        return if raw_path.match?(/\$\{(?!path\.module\})/)

        tf_dir = File.dirname(File.expand_path(tf_file, @project_root))
        expanded = raw_path.gsub('${path.module}', tf_dir)
        File.expand_path(expanded)
      end

      def ensure_zip!(artifact)
        label = relative_to_root(artifact.zip_path)
        zip_exists = File.file?(artifact.zip_path)
        hashed = File.file?(hash_file_for(artifact))

        if zip_exists && (!hashed || hash_unchanged?(artifact))
          puts "  ♻️  #{label} unchanged — skipping rebuild" if hashed
          return
        end

        puts "  📦 Building #{label}..."
        if node_package?(artifact.source_dir)
          build_node_zip!(artifact)
        else
          build_js_zip!(artifact)
        end
        write_hash!(artifact)
        puts "  ✅ #{label} ready"
      end

      def node_package?(dir)
        File.file?(File.join(dir, 'package.json'))
      end

      def build_node_zip!(artifact)
        ensure_docker!
        install_node_modules!(artifact.source_dir)
        zip_contents!(artifact, node_zip_entries(artifact.source_dir))
      end

      def build_js_zip!(artifact)
        entries = js_zip_entries(artifact.source_dir)
        abort "✗ #{relative_to_root(artifact.source_dir)} has no .js/.mjs files to zip" if entries.empty?

        zip_contents!(artifact, entries)
      end

      def node_zip_entries(dir)
        entries = js_zip_entries(dir)
        entries << 'package.json' if File.file?(File.join(dir, 'package.json'))
        entries << 'node_modules' if Dir.exist?(File.join(dir, 'node_modules'))
        entries.uniq
      end

      def js_zip_entries(dir)
        Dir.children(dir).grep(/\.(mjs|js|cjs)\z/).sort
      end

      def install_node_modules!(source_dir)
        lockfile = File.join(source_dir, 'package-lock.json')
        install = File.file?(lockfile) ? 'npm ci --omit=dev' : 'npm install --omit=dev'
        uid = Process.uid
        gid = Process.gid

        docker_cmd = [
          'docker', 'run', '--rm',
          '--platform', 'linux/amd64',
          '--entrypoint', '',
          '-v', "#{source_dir}:/var/task",
          '-w', '/var/task',
          NODE_DOCKER_IMAGE,
          '/bin/bash', '-c',
          "rm -rf node_modules && #{install} && chown -R #{uid}:#{gid} ."
        ]

        output, status = Open3.capture2e(*docker_cmd)
        return if status.success?

        puts output
        abort "\n✗ Node Lambda build failed for #{relative_to_root(source_dir)}. " \
              'Is Docker running?'
      end

      def zip_contents!(artifact, entries)
        FileUtils.rm_f(artifact.zip_path)
        zip_name = File.basename(artifact.zip_path)

        Dir.chdir(artifact.source_dir) do
          output, status = Open3.capture2e('zip', '-qr', zip_name, *entries)
          unless status.success?
            puts output
            abort "\n✗ zip failed for #{relative_to_root(artifact.zip_path)}"
          end
        end
      end

      def ensure_docker!
        _, status = Open3.capture2e('docker', 'info')
        return if status.success?

        abort "✗ Docker is not running. It's required to build Node Lambda zips for linux/amd64."
      end

      def hash_unchanged?(artifact)
        hash_file = hash_file_for(artifact)
        return false unless File.file?(hash_file)

        File.read(hash_file).strip == source_hash(artifact.source_dir)
      end

      def write_hash!(artifact)
        File.write(hash_file_for(artifact), "#{source_hash(artifact.source_dir)}\n")
      end

      def hash_file_for(artifact)
        File.join(artifact.source_dir, ".#{File.basename(artifact.source_dir)}-hash")
      end

      def source_hash(dir)
        files = Dir.children(dir).select do |name|
          name.match?(/\.(mjs|js|cjs)\z/) || name == 'package.json' || name == 'package-lock.json'
        end.sort

        digest = Digest::SHA256.new
        files.each { |name| digest.update(File.binread(File.join(dir, name))) }
        digest.hexdigest
      end

      def relative_to_root(path)
        path.sub(%r{\A#{Regexp.escape(@project_root)}/?}, '')
      end
    end
  end
end
