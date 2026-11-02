# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'belt/cli/frontend_deploy_command'

RSpec.describe Belt::CLI::FrontendDeployCommand do
  describe '#sync_to_s3' do
    around do |example|
      Dir.mktmpdir do |dir|
        @dist = File.join(dir, 'dist')
        FileUtils.mkdir_p(File.join(@dist, '_pages', 'docs'))
        File.write(File.join(@dist, 'index.html'), '<html></html>')
        File.write(File.join(@dist, '_pages', 'docs', 'agents.html'), '<html></html>')
        example.run
      end
    end

    let(:frontend) do
      instance_double(Belt::CLI::Frontend, dist_dir: @dist, label: 'frontend', path: 'frontend')
    end
    let(:command) { described_class.new('dev', frontend: frontend) }
    let(:calls) { [] }

    before do
      allow(command).to receive(:fetch_bucket_name).and_return('bucket')
      allow(command).to receive(:run!) { |*args| calls << args }
      allow(command).to receive(:puts)
    end

    it 'keeps every HTML file out of the immutable, size-only asset sync' do
      command.send(:sync_to_s3)

      assets = calls.find { |args| args.include?('public, max-age=31536000, immutable') }
      expect(assets).to include('--size-only')
      expect(assets.each_cons(2).to_a).to include(['--exclude', '*.html'])
    end

    it 'syncs every HTML file, prerendered pages included, with no-cache and without --size-only' do
      command.send(:sync_to_s3)

      html = calls.find { |args| args.include?('--include') }
      expect(html.each_cons(2).to_a).to include(%w[--exclude *], %w[--include *.html], %w[--cache-control no-cache])
      expect(html).to include('--delete')
      expect(html).not_to include('--size-only')
    end
  end
end
