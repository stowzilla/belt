# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/frontend_env_command'

RSpec.describe Belt::CLI::FrontendEnvCommand do
  let(:tmpdir) { Dir.mktmpdir }

  before do
    @original_dir = Dir.pwd
    Dir.chdir(tmpdir)
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(tmpdir)
  end

  def create_file(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def stub_tf_output(outputs)
    allow(Open3).to receive(:capture2) do |*args, **_kwargs|
      name = args[3]
      value = outputs[name]
      if value
        [value, instance_double(Process::Status, success?: true)]
      else
        ['', instance_double(Process::Status, success?: false)]
      end
    end
  end

  describe '.run' do
    it 'shows usage and exits 1 when no subcommand given' do
      expect { described_class.run([]) }
        .to output(/Frontend helpers/).to_stdout
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'shows usage and exits 0 with --help' do
      expect { described_class.run(['--help']) }
        .to output(/Frontend helpers/).to_stdout
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it 'shows usage and exits 0 with -h' do
      expect { described_class.run(['-h']) }
        .to output(/Frontend helpers/).to_stdout
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it 'exits with error for unknown subcommand' do
      expect { described_class.run(['unknown']) }
        .to output(/Unknown frontend subcommand: unknown/).to_stdout
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  describe '.run_env' do
    it 'exits with usage when no environment given' do
      expect { described_class.run(['env']) }
        .to output(/Usage: belt frontend env/).to_stdout
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'resolves environment from BELT_ENV when no args given' do
      FileUtils.mkdir_p('frontend')
      FileUtils.mkdir_p('infrastructure/staging')
      # Create a Gemfile so app detection works
      File.write('Gemfile', "source 'https://rubygems.org'\n")
      stub_tf_output('api_url' => 'https://staging.example.com')

      allow(ENV).to receive(:fetch).with('BELT_ENV', nil).and_return('staging')

      expect { described_class.run(['env']) }
        .to output(/Updated/).to_stdout
    end

    it 'aborts when frontend/ directory is missing' do
      FileUtils.mkdir_p('infrastructure/dev')
      File.write('Gemfile', "source 'https://rubygems.org'\n")
      stub_tf_output('api_url' => 'https://dev.example.com')

      expect { described_class.run(%w[env dev]) }
        .to raise_error(SystemExit)
    end

    it 'aborts when infrastructure/<env> is missing' do
      FileUtils.mkdir_p('frontend')
      File.write('Gemfile', "source 'https://rubygems.org'\n")
      stub_tf_output('api_url' => 'https://dev.example.com')

      expect { described_class.run(%w[env dev]) }
        .to raise_error(SystemExit)
    end

    it 'writes .env from terraform outputs with default map' do
      FileUtils.mkdir_p('frontend')
      FileUtils.mkdir_p('infrastructure/dev')
      File.write('Gemfile', "source 'https://rubygems.org'\n")
      stub_tf_output('api_url' => 'https://dev.example.com')

      expect { described_class.run(%w[env dev]) }
        .to output(%r{No frontend/env.yml \(or .yaml\) found.*default map}m).to_stdout

      content = File.read('frontend/.env')
      expect(content).to include('VITE_API_URL=https://dev.example.com')
    end

    it 'uses custom env map when present' do
      FileUtils.mkdir_p('frontend')
      FileUtils.mkdir_p('infrastructure/dev')
      File.write('Gemfile', "source 'https://rubygems.org'\n")
      create_file('frontend/env.yml', <<~YAML)
        VITE_API_URL: api_url
        VITE_POOL_ID: pool_id
      YAML
      stub_tf_output('api_url' => 'https://dev.example.com', 'pool_id' => 'us-east-1_ABC123')

      expect { described_class.run(%w[env dev]) }
        .to output(%r{Loading env map from frontend/env.yml}m).to_stdout

      content = File.read('frontend/.env')
      expect(content).to include('VITE_API_URL=https://dev.example.com')
      expect(content).to include('VITE_POOL_ID=us-east-1_ABC123')
    end

    it 'warns when no values are written' do
      FileUtils.mkdir_p('frontend')
      FileUtils.mkdir_p('infrastructure/dev')
      File.write('Gemfile', "source 'https://rubygems.org'\n")
      stub_tf_output({})

      expect { described_class.run(%w[env dev]) }
        .to output(/No values written.*terraform outputs missing/).to_stdout
    end
  end
end
