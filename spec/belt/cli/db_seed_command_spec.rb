# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'belt/cli/db_seed_command'
require 'fileutils'
require 'tmpdir'

RSpec.describe Belt::CLI::DbSeedCommand do
  def aws_success(json)
    [JSON.generate(json), instance_double(Process::Status, success?: true)]
  end

  def seed_ran?
    File.exist?('seed_ran.marker')
  end

  around do |example|
    Dir.mktmpdir do |tmpdir|
      FileUtils.mkdir_p(File.join(tmpdir, 'lambda'))
      File.write(File.join(tmpdir, 'lambda', 'api.rb'), '# gateway :api')
      FileUtils.mkdir_p(File.join(tmpdir, 'config'))
      File.write(File.join(tmpdir, 'config', 'routes.rb'), '')

      Dir.chdir(tmpdir) do
        Belt.root = nil
        previous_gemfile = ENV.fetch('BUNDLE_GEMFILE', nil)
        ENV['BUNDLE_GEMFILE'] = File.join(tmpdir, 'Gemfile')
        File.write(ENV.fetch('BUNDLE_GEMFILE', nil), '')
        example.run
        Belt.root = nil
        if previous_gemfile
          ENV['BUNDLE_GEMFILE'] = previous_gemfile
        else
          ENV.delete('BUNDLE_GEMFILE')
        end
      end
    end
  end

  it 'aborts when config/seeds.rb does not exist' do
    expect { described_class.run([]) }.to raise_error(SystemExit)
  end

  context 'with a seeds.rb present' do
    before do
      File.write('config/seeds.rb', "FileUtils.touch('seed_ran.marker')\n")
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json')
                                        .and_return(aws_success('TableNames' => []))
    end

    it 'defaults to the dev environment and loads seeds.rb' do
      expect { described_class.run([]) }.to output(%r{seeding dev from config/seeds\.rb}).to_stdout
      expect(seed_ran?).to be true
    end

    it 'accepts an explicit environment argument' do
      expect { described_class.run(['dev01']) }.to output(/seeding dev01/).to_stdout
    end
  end

  context 'when the target environment already has data' do
    before do
      FileUtils.mkdir_p('infrastructure/dev')
      File.write('infrastructure/dev/terraform.tfvars', 'app_name = "myapp"')
      File.write('config/seeds.rb', "FileUtils.touch('seed_ran.marker')\n")
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json')
                                        .and_return(aws_success('TableNames' => ['myapp-dev-posts']))
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-dev-posts', '--select', 'COUNT', '--limit', '1',
        '--output', 'json'
      ).and_return(aws_success('Count' => 2))
    end

    it 'refuses to seed without --force' do
      expect { described_class.run([]) }.to raise_error(SystemExit)
      expect(seed_ran?).to be false
    end

    it 'seeds anyway when --force is passed' do
      expect { described_class.run(['--force']) }.to output(/seeding dev/).to_stdout
      expect(seed_ran?).to be true
    end
  end
end
