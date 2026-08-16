# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/frontend_env_map'

RSpec.describe Belt::CLI::FrontendEnvMap do
  let(:tmpdir) { Dir.mktmpdir }
  let(:original_dir) { Dir.pwd }

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
      name = args[3] # 'terraform', 'output', '-raw', name
      value = outputs[name]
      if value
        [value, instance_double(Process::Status, success?: true)]
      else
        ['', instance_double(Process::Status, success?: false)]
      end
    end
  end

  describe '.find_map_path' do
    it 'returns nil when no map file exists' do
      expect(described_class.find_map_path).to be_nil
    end

    it 'finds frontend/env.yml first' do
      create_file('frontend/env.yml', "VITE_API_URL: api_url\n")
      create_file('.belt/frontend_env.yml', "VITE_API_URL: api_url\n")
      expect(described_class.find_map_path).to eq('frontend/env.yml')
    end

    it 'falls back to .belt/frontend_env.yml' do
      create_file('.belt/frontend_env.yml', "VITE_API_URL: api_url\n")
      expect(described_class.find_map_path).to eq('.belt/frontend_env.yml')
    end

    it 'finds frontend/env.yaml' do
      create_file('frontend/env.yaml', "VITE_API_URL: api_url\n")
      expect(described_class.find_map_path).to eq('frontend/env.yaml')
    end

    it 'finds .belt/frontend_env.yaml' do
      create_file('.belt/frontend_env.yaml', "VITE_API_URL: api_url\n")
      expect(described_class.find_map_path).to eq('.belt/frontend_env.yaml')
    end

    it 'prefers .yml over .yaml in the same directory' do
      create_file('frontend/env.yml', "VITE_API_URL: api_url\n")
      create_file('frontend/env.yaml', "VITE_API_URL: other\n")
      expect(described_class.find_map_path).to eq('frontend/env.yml')
    end

    it 'prefers frontend/ over .belt/ regardless of extension' do
      create_file('frontend/env.yaml', "VITE_API_URL: api_url\n")
      create_file('.belt/frontend_env.yml', "VITE_API_URL: other\n")
      expect(described_class.find_map_path).to eq('frontend/env.yaml')
    end
  end

  describe '#initialize' do
    it 'uses the default map when no map file exists' do
      map = described_class.new('dev')
      expect(map.map).to eq({ 'VITE_API_URL' => 'api_url' })
      expect(map.using_default_map?).to be true
    end

    it 'loads a custom map from frontend/env.yml' do
      create_file('frontend/env.yml', <<~YAML)
        VITE_API_URL: api_url
        VITE_COGNITO_POOL: cognito_user_pool_id
      YAML

      map = described_class.new('dev')
      expect(map.map).to eq({
                              'VITE_API_URL' => 'api_url',
                              'VITE_COGNITO_POOL' => 'cognito_user_pool_id'
                            })
      expect(map.using_default_map?).to be false
    end

    it 'loads a custom map from frontend/env.yaml' do
      create_file('frontend/env.yaml', <<~YAML)
        VITE_API_URL: api_url
        VITE_REGION: aws_region
      YAML

      map = described_class.new('dev')
      expect(map.map).to eq({
                              'VITE_API_URL' => 'api_url',
                              'VITE_REGION' => 'aws_region'
                            })
      expect(map.using_default_map?).to be false
    end

    it 'defaults env_dir to infrastructure/<env_name>' do
      map = described_class.new('staging')
      expect(map.env_dir).to eq('infrastructure/staging')
    end

    it 'accepts a custom env_dir' do
      map = described_class.new('prod', env_dir: '/custom/path')
      expect(map.env_dir).to eq('/custom/path')
    end

    it 'aborts when YAML map is empty' do
      create_file('frontend/env.yml', "---\n")
      expect { described_class.new('dev') }.to raise_error(SystemExit)
    end

    it 'aborts when YAML map is not a hash' do
      create_file('frontend/env.yml', "- item1\n- item2\n")
      expect { described_class.new('dev') }.to raise_error(SystemExit)
    end

    it 'aborts when YAML map has only blank entries' do
      create_file('frontend/env.yml', "\" \": \" \"\n")
      expect { described_class.new('dev') }.to raise_error(SystemExit)
    end

    it 'aborts on invalid YAML syntax' do
      create_file('frontend/env.yml', "invalid: yaml: content: [unbalanced\n")
      expect { described_class.new('dev') }.to raise_error(SystemExit)
    end

    it 'strips whitespace from keys and values in the map' do
      create_file('frontend/env.yml', "  VITE_API_URL : api_url  \n")
      map = described_class.new('dev')
      expect(map.map).to eq({ 'VITE_API_URL' => 'api_url' })
    end
  end

  describe '#process_env' do
    before do
      FileUtils.mkdir_p('infrastructure/dev')
    end

    it 'resolves terraform outputs for default map' do
      stub_tf_output('api_url' => 'https://api.example.com')

      map = described_class.new('dev')
      expect(map.process_env).to eq({ 'VITE_API_URL' => 'https://api.example.com' })
    end

    it 'resolves multiple outputs from custom map' do
      create_file('frontend/env.yml', <<~YAML)
        VITE_API_URL: api_url
        VITE_REGION: aws_region
      YAML
      stub_tf_output('api_url' => 'https://api.dev.example.com', 'aws_region' => 'us-east-1')

      map = described_class.new('dev')
      expect(map.process_env).to eq({
                                      'VITE_API_URL' => 'https://api.dev.example.com',
                                      'VITE_REGION' => 'us-east-1'
                                    })
    end

    it 'skips keys with missing terraform outputs' do
      create_file('frontend/env.yml', <<~YAML)
        VITE_API_URL: api_url
        VITE_MISSING: nonexistent_output
      YAML
      stub_tf_output('api_url' => 'https://api.example.com')

      map = described_class.new('dev')
      expect(map.process_env).to eq({ 'VITE_API_URL' => 'https://api.example.com' })
    end

    it 'treats "null" terraform output as missing' do
      stub_tf_output('api_url' => 'null')

      map = described_class.new('dev')
      expect(map.process_env).to eq({})
    end

    it 'treats empty terraform output as missing' do
      stub_tf_output('api_url' => '   ')

      map = described_class.new('dev')
      expect(map.process_env).to eq({})
    end

    it 'returns empty hash when env_dir does not exist' do
      map = described_class.new('nonexistent')
      expect(map.process_env).to eq({})
    end

    it 'caches terraform outputs (calls once per output name)' do
      FileUtils.mkdir_p('infrastructure/dev')
      call_count = 0
      allow(Open3).to receive(:capture2) do |*_args, **_kwargs|
        call_count += 1
        ['https://api.example.com', instance_double(Process::Status, success?: true)]
      end

      map = described_class.new('dev')
      map.process_env
      map.process_env

      expect(call_count).to eq(1)
    end
  end

  describe '#write_dotenv!' do
    let(:dotenv_path) { File.join(tmpdir, 'frontend', '.env') }

    before do
      FileUtils.mkdir_p('infrastructure/dev')
      FileUtils.mkdir_p('frontend')
      stub_tf_output('api_url' => 'https://api.example.com')
    end

    it 'creates frontend/.env when it does not exist' do
      map = described_class.new('dev')
      result = map.write_dotenv!

      expect(File.exist?(dotenv_path)).to be true
      expect(File.read(dotenv_path)).to include('VITE_API_URL=https://api.example.com')
      expect(result[:updated]).to eq(['VITE_API_URL'])
      expect(result[:missing]).to eq([])
    end

    it 'updates existing keys in .env' do
      File.write(dotenv_path, "VITE_API_URL=old_value\nMY_SECRET=keep_me\n")

      map = described_class.new('dev')
      result = map.write_dotenv!

      content = File.read(dotenv_path)
      expect(content).to include('VITE_API_URL=https://api.example.com')
      expect(content).to include('MY_SECRET=keep_me')
      expect(result[:updated]).to eq(['VITE_API_URL'])
    end

    it 'preserves comments and blank lines' do
      File.write(dotenv_path, "# Important comment\n\nVITE_API_URL=old\n\n# Another comment\n")

      map = described_class.new('dev')
      map.write_dotenv!

      content = File.read(dotenv_path)
      expect(content).to include('# Important comment')
      expect(content).to include('# Another comment')
      expect(content).to include('VITE_API_URL=https://api.example.com')
    end

    it 'appends new keys that do not exist yet' do
      File.write(dotenv_path, "EXISTING_KEY=existing_value\n")

      map = described_class.new('dev')
      map.write_dotenv!

      content = File.read(dotenv_path)
      expect(content).to include('EXISTING_KEY=existing_value')
      expect(content).to include('VITE_API_URL=https://api.example.com')
    end

    it 'preserves keys with export prefix' do
      File.write(dotenv_path, "export VITE_API_URL=old\n")

      map = described_class.new('dev')
      map.write_dotenv!

      content = File.read(dotenv_path)
      # The line gets replaced (not prefixed with export in the new format)
      expect(content).to include('VITE_API_URL=https://api.example.com')
    end

    it 'reports missing terraform outputs without clobbering existing values' do
      create_file('frontend/env.yml', <<~YAML)
        VITE_API_URL: api_url
        VITE_MISSING: nonexistent
      YAML
      stub_tf_output('api_url' => 'https://api.example.com')
      File.write(dotenv_path, "VITE_MISSING=keep_this\n")

      map = described_class.new('dev')
      result = map.write_dotenv!

      content = File.read(dotenv_path)
      expect(content).to include('VITE_MISSING=keep_this')
      expect(result[:missing]).to eq(['VITE_MISSING'])
    end

    it 'writes to a custom path' do
      custom_path = File.join(tmpdir, 'custom', '.env')
      map = described_class.new('dev')
      result = map.write_dotenv!(path: custom_path)

      expect(File.exist?(custom_path)).to be true
      expect(result[:path]).to eq(custom_path)
    end

    it 'escapes values with special characters' do
      stub_tf_output('api_url' => 'https://api.example.com/path with spaces#anchor')

      map = described_class.new('dev')
      map.write_dotenv!

      content = File.read(dotenv_path)
      expect(content).to include('VITE_API_URL="https://api.example.com/path with spaces#anchor"')
    end

    it 'does not escape simple values' do
      stub_tf_output('api_url' => 'https://api.example.com')

      map = described_class.new('dev')
      map.write_dotenv!

      content = File.read(dotenv_path)
      expect(content).to include('VITE_API_URL=https://api.example.com')
      expect(content).not_to include('"https://api.example.com"')
    end

    it 'escapes values with dollar signs' do
      stub_tf_output('api_url' => 'value$with$dollars')

      map = described_class.new('dev')
      map.write_dotenv!

      content = File.read(dotenv_path)
      expect(content).to include('VITE_API_URL="value$with$dollars"')
    end

    it 'escapes values with backslashes and quotes' do
      stub_tf_output('api_url' => 'value\\with"quotes')

      map = described_class.new('dev')
      map.write_dotenv!

      content = File.read(dotenv_path)
      # The value contains a backslash and a quote, so it should be wrapped
      # in double quotes with backslash doubled and quote escaped.
      # Input chars:  v a l u e \ w i t h " q u o t e s
      # Output line:  VITE_API_URL="value\\with\"quotes"
      expect(content).to include('VITE_API_URL="value\\\\with\\"quotes"')
    end
  end

  describe 'terraform output handling edge cases' do
    before do
      FileUtils.mkdir_p('infrastructure/dev')
    end

    it 'handles Errno::ENOENT when terraform is not installed' do
      allow(Open3).to receive(:capture2).and_raise(Errno::ENOENT)

      map = described_class.new('dev')
      expect(map.process_env).to eq({})
    end
  end
end
