# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/frontend_setup_command'

RSpec.describe Belt::CLI::FrontendSetupCommand do
  let(:tmpdir) { Dir.mktmpdir }
  let(:module_dir) { File.join(tmpdir, described_class::MODULE_DIR) }

  around do |example|
    FileUtils.mkdir_p(module_dir)
    Dir.chdir(tmpdir) { example.run }
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it 'generates a distribution whose router answers 404 for unknown addresses' do
    described_class.new(nil, quiet: true).run
    terraform = File.read(File.join(module_dir, 'frontend.tf'))

    expect(terraform).to include('resource "aws_cloudfront_key_value_store" "frontend_routes"')
    %w[request response].each do |event|
      expect(terraform).to include(%(event_type   = "viewer-#{event}"))
      expect(terraform).to include("function_arn = aws_cloudfront_function.frontend_route_#{event}.arn")
    end
    expect(terraform.scan('[aws_cloudfront_key_value_store.frontend_routes.arn]').size).to eq(2)
    expect(terraform.scan(%(file("${path.module}/#{Belt::CLI::FrontendRoutes::ROUTER_FILE}"))).size).to eq(2)
    # The SPA fallback stays: it is what serves before routes are first published.
    expect(terraform.scan('response_page_path = "/index.html"').size).to eq(2)
  end

  it 'puts the router function beside the terraform that loads it' do
    described_class.new(nil, quiet: true).run

    expect(File.read(File.join(module_dir, Belt::CLI::FrontendRoutes::ROUTER_FILE)))
      .to eq(File.read(Belt::CLI::FrontendRoutes::ROUTER_SOURCE))
  end
end
