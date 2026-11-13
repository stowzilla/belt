# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/frontend_routes'

RSpec.describe Belt::CLI::FrontendRoutes do
  let(:tmpdir) { Dir.mktmpdir }
  let(:routes) { described_class.new(dist_dir: tmpdir, distribution_id: 'E123') }
  let(:store_arn) { 'arn:aws:cloudfront::123456789012:key-value-store/abc' }
  let(:calls) { [] }
  let(:ok) { instance_double(Process::Status, success?: true) }
  let(:failed) { instance_double(Process::Status, success?: false) }

  after { FileUtils.rm_rf(tmpdir) }

  def write_manifest(data = { 'pages' => ['/pricing'], 'app' => ['/login', '/projects/*'] })
    File.write(File.join(tmpdir, described_class::MANIFEST), JSON.generate(data))
  end

  # Answers each aws call from the first response whose key appears in the command.
  def stub_aws(responses)
    allow(Open3).to receive(:capture3) do |*cmd|
      calls << cmd
      _, body = responses.find { |match, _| cmd.join(' ').include?(match) }
      body ? [JSON.generate(body), '', ok] : ['', 'unexpected call', failed]
    end
  end

  def router_on_distribution
    {
      'get-distribution-config' => { 'DistributionConfig' => { 'DefaultCacheBehavior' => { 'FunctionAssociations' => {
        'Items' => [{ 'FunctionARN' => 'arn:aws:cloudfront::123456789012:function/app-dev-frontend-route-req' }]
      } } } },
      'describe-function' => { 'FunctionSummary' => { 'FunctionConfig' => { 'KeyValueStoreAssociations' => {
        'Items' => [{ 'KeyValueStoreARN' => store_arn }]
      } } } },
      'describe-key-value-store' => { 'ETag' => 'ETAG1' }
    }
  end

  it 'does nothing without a routes manifest' do
    expect(Open3).not_to receive(:capture3)

    expect(routes.publish).to eq(:no_manifest)
  end

  it 'publishes the routes to the store the distribution router reads, replacing stale chunks' do
    write_manifest
    stub_aws(router_on_distribution.merge(
               'list-keys' => { 'Items' => [{ 'Key' => 'belt:routes' }, { 'Key' => 'belt:routes:0' },
                                            { 'Key' => 'belt:routes:1' }, { 'Key' => 'someone-elses-key' }] },
               'update-keys' => { 'ETag' => 'ETAG2' }
             ))

    expect { expect(routes.publish).to eq(:published) }
      .to output(/Published routes: 1 page\(s\), 2 app path\(s\)/).to_stdout

    update = calls.find { |cmd| cmd.include?('update-keys') }
    expect(update).to include('--kvs-arn', store_arn, '--if-match', 'ETAG1')
    puts_arg = JSON.parse(update[update.index('--puts') + 1]).to_h { |entry| [entry['Key'], entry['Value']] }
    expect(puts_arg['belt:routes']).to eq('1')
    expect(JSON.parse(puts_arg['belt:routes:0'])).to eq('app' => ['/login', '/projects/*'], 'pages' => ['/pricing'])
    expect(JSON.parse(update[update.index('--deletes') + 1])).to eq([{ 'Key' => 'belt:routes:1' }])
    expect(calls.find { |cmd| cmd.include?('describe-function') }).to include('app-dev-frontend-route-req', 'LIVE')
  end

  it 'says so and deploys on when the distribution has no router yet' do
    write_manifest
    stub_aws('get-distribution-config' => { 'DistributionConfig' => { 'DefaultCacheBehavior' => {} } })

    expect { expect(routes.publish).to eq(:no_router) }.to output(/Unknown paths still answer 200/).to_stdout
    expect(calls.size).to eq(1)
  end

  it 'warns instead of failing the deploy when the store cannot be written' do
    write_manifest
    stub_aws(router_on_distribution)

    expect { expect(routes.publish).to eq(:failed) }.to output(/Could not publish routes \(unexpected call\)/).to_stderr
  end

  describe '.install_router' do
    it 'copies the gem router function and reports nothing when it is already current' do
      dest = described_class.install_router(tmpdir)

      expect(dest).to eq(File.join(tmpdir, described_class::ROUTER_FILE))
      expect(File.read(dest)).to eq(File.read(described_class::ROUTER_SOURCE))
      expect(described_class.install_router(tmpdir)).to be_nil
    end
  end
end
