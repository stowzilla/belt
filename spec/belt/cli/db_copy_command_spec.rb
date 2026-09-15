# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/db_copy_command'
require 'fileutils'
require 'tmpdir'

RSpec.describe Belt::CLI::DbCopyCommand do
  around do |example|
    Dir.mktmpdir do |tmpdir|
      FileUtils.mkdir_p(File.join(tmpdir, 'lambda'))
      File.write(File.join(tmpdir, 'lambda', 'api.rb'), '# gateway :api')
      FileUtils.mkdir_p(File.join(tmpdir, 'infrastructure', 'prod'))
      File.write(File.join(tmpdir, 'infrastructure', 'prod', 'terraform.tfvars'), 'app_name = "myapp"')

      Dir.chdir(tmpdir) { example.run }
    end
  end

  it 'shows usage and exits when from/to envs are missing' do
    expect { described_class.run(['prod']) }.to raise_error(SystemExit)
  end

  it 'aborts when source and destination are the same' do
    expect { described_class.run(%w[prod prod]) }.to raise_error(SystemExit)
  end

  it 'resolves per-environment aws profiles from belt.rb and drives DynamoCopier' do
    File.write(File.join('infrastructure', 'prod', 'belt.rb'), <<~RUBY)
      Belt.configure do |config|
        config.aws_profile = "prod-readonly"
      end
    RUBY
    FileUtils.mkdir_p('infrastructure/dev')
    File.write('infrastructure/dev/belt.rb', <<~RUBY)
      Belt.configure do |config|
        config.aws_profile = "dev"
      end
    RUBY

    copier = instance_double(Belt::CLI::DynamoCopier, run: true)
    expect(Belt::CLI::DynamoCopier).to receive(:new).with(
      from_prefixes: ['myapp-prod-'],
      to_prefixes: ['myapp-dev-'],
      from_profile: 'prod-readonly',
      to_profile: 'dev',
      force: false,
      label: 'prod → dev'
    ).and_return(copier)

    expect { described_class.run(%w[prod dev]) }.to output(/copying DynamoDB data: prod → dev/).to_stdout
  end

  it 'honors --force and explicit profile overrides' do
    copier = instance_double(Belt::CLI::DynamoCopier, run: true)
    expect(Belt::CLI::DynamoCopier).to receive(:new).with(
      from_prefixes: ['myapp-prod-'],
      to_prefixes: ['myapp-dev-'],
      from_profile: 'custom-from',
      to_profile: 'custom-to',
      force: true,
      label: 'prod → dev'
    ).and_return(copier)

    described_class.run(%w[prod dev --force --from-profile custom-from --to-profile custom-to])
  end

  it 'aborts with a non-zero exit when the copier reports failure' do
    allow(Belt::CLI::DynamoCopier).to receive(:new).and_return(instance_double(Belt::CLI::DynamoCopier, run: false))

    expect { described_class.run(%w[prod dev]) }.to raise_error(SystemExit)
  end
end
