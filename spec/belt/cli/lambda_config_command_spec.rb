# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/lambda_config_command'
require 'tmpdir'
require 'fileutils'
require 'json'

RSpec.describe Belt::CLI::LambdaConfigCommand do
  around do |example|
    original_dir = Dir.pwd
    Dir.mktmpdir do |dir|
      Dir.chdir(dir)
      example.run
    end
  ensure
    Dir.chdir(original_dir)
  end

  def create_config(name, content)
    FileUtils.mkdir_p('config/lambda')
    File.write("config/lambda/#{name}.yml", content)
  end

  describe '.load_configs' do
    it 'loads and merges config for the specified environment' do
      create_config('customer', <<~YAML)
        default: &default
          timeout: 60
          memory_size: 512
          env_keys:
            - IMAGES_BUCKET_NAME

        dev:
          <<: *default
          memory_size: 256

        prod:
          <<: *default
          memory_size: 1024
      YAML

      configs = described_class.load_configs(environment: 'dev', config_dir: 'config/lambda')
      expect(configs['customer']['timeout']).to eq(60)
      expect(configs['customer']['memory_size']).to eq(256)
      expect(configs['customer']['env_keys']).to eq(['IMAGES_BUCKET_NAME'])
    end

    it 'uses prod overrides when environment is prod' do
      create_config('customer', <<~YAML)
        default: &default
          timeout: 60
          memory_size: 512

        dev:
          <<: *default
          memory_size: 256

        prod:
          <<: *default
          timeout: 30
          memory_size: 1024
      YAML

      configs = described_class.load_configs(environment: 'prod', config_dir: 'config/lambda')
      expect(configs['customer']['timeout']).to eq(30)
      expect(configs['customer']['memory_size']).to eq(1024)
    end

    it 'falls back to default when environment has no overrides' do
      create_config('api', <<~YAML)
        default: &default
          timeout: 30
          memory_size: 256

        dev:
          <<: *default

        prod:
          <<: *default
          memory_size: 512
      YAML

      configs = described_class.load_configs(environment: 'dev', config_dir: 'config/lambda')
      expect(configs['api']['timeout']).to eq(30)
      expect(configs['api']['memory_size']).to eq(256)
    end

    it 'loads multiple lambda configs from the directory' do
      create_config('customer', <<~YAML)
        default:
          timeout: 60
          memory_size: 512
      YAML

      create_config('ops', <<~YAML)
        default:
          timeout: 60
          memory_size: 1024
      YAML

      create_config('worker', <<~YAML)
        default:
          timeout: 300
          memory_size: 256
      YAML

      configs = described_class.load_configs(environment: 'dev', config_dir: 'config/lambda')
      expect(configs.keys.sort).to eq(%w[customer ops worker])
      expect(configs['worker']['timeout']).to eq(300)
    end

    it 'returns empty hash when directory does not exist' do
      configs = described_class.load_configs(environment: 'dev', config_dir: 'config/lambda')
      expect(configs).to eq({})
    end

    it 'handles env_vars as static key-value pairs' do
      create_config('api', <<~YAML)
        default: &default
          timeout: 30
          env_vars:
            WELCOME_TITLE: "Hello World"
            DEBUG: "true"

        prod:
          <<: *default
          env_vars:
            WELCOME_TITLE: "Production App"
            DEBUG: "false"
      YAML

      dev_configs = described_class.load_configs(environment: 'dev', config_dir: 'config/lambda')
      expect(dev_configs['api']['env_vars']['WELCOME_TITLE']).to eq('Hello World')

      prod_configs = described_class.load_configs(environment: 'prod', config_dir: 'config/lambda')
      expect(prod_configs['api']['env_vars']['WELCOME_TITLE']).to eq('Production App')
    end

    it 'supports ephemeral_storage and reserved_concurrency' do
      create_config('heavy', <<~YAML)
        default:
          timeout: 120
          memory_size: 1024
          ephemeral_storage: 2048
          reserved_concurrency: 5
      YAML

      configs = described_class.load_configs(environment: 'dev', config_dir: 'config/lambda')
      expect(configs['heavy']['ephemeral_storage']).to eq(2048)
      expect(configs['heavy']['reserved_concurrency']).to eq(5)
    end
  end

  describe '#run (json output)' do
    it 'outputs JSON to stdout' do
      create_config('api', <<~YAML)
        default:
          timeout: 30
          memory_size: 256
      YAML

      output = capture_stdout do
        described_class.new(environment: 'dev', format: 'json').run
      end

      parsed = JSON.parse(output)
      expect(parsed['api']['timeout']).to eq(30)
    end
  end

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
