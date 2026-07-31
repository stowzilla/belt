# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli'
require 'tmpdir'
require 'fileutils'

RSpec.describe Belt::CLI::ContractsCommand do
  around do |example|
    Belt.root = nil
    original_dir = Dir.pwd
    example.run
  ensure
    Dir.chdir(original_dir)
    Belt.root = nil
  end

  let(:contracts_content) do
    <<~RUBY
      Belt.application.schema.define do
        request :create_post do
          string :title, required: true
          string :body, required: true
          string :status
        end

        model :post do
          string :id
          string :title
          string :body
          string :created_at
        end
      end
    RUBY
  end

  def setup_contracts_file(dir, filename: 'config/contracts.rb')
    path = File.join(dir, filename)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contracts_content)
    path
  end

  describe '.run' do
    context 'when no contracts file exists' do
      it 'aborts with an error message' do
        Dir.mktmpdir do |dir|
          Dir.chdir(dir)
          expect { described_class.run([]) }.to raise_error(SystemExit)
        end
      end
    end

    context 'with config/contracts.rb' do
      it 'outputs concise format by default' do
        Dir.mktmpdir do |dir|
          setup_contracts_file(dir)
          Dir.chdir(dir)

          expect { described_class.run([]) }.to output(/REQUEST MODELS/).to_stdout
        end
      end
    end

    context 'with -f json' do
      it 'outputs JSON with models array' do
        Dir.mktmpdir do |dir|
          setup_contracts_file(dir)
          Dir.chdir(dir)

          output = capture_stdout { described_class.run(['-f', 'json']) }
          parsed = JSON.parse(output)

          expect(parsed).to have_key('models')
          expect(parsed['models'].length).to be >= 1
        end
      end
    end

    context 'with -g pattern' do
      it 'filters models by name' do
        Dir.mktmpdir do |dir|
          setup_contracts_file(dir)
          Dir.chdir(dir)

          output = capture_stdout { described_class.run(['-f', 'json', '-g', 'create']) }
          parsed = JSON.parse(output)

          expect(parsed['models'].all? { |m| m['name'].match?(/create/i) }).to be true
        end
      end
    end

    context 'with legacy config/schema.tf.rb' do
      it 'finds and loads the legacy file' do
        Dir.mktmpdir do |dir|
          setup_contracts_file(dir, filename: 'config/schema.tf.rb')
          Dir.chdir(dir)

          expect { described_class.run([]) }.to output(/REQUEST MODELS/).to_stdout
        end
      end
    end

    context 'with --file override' do
      it 'uses the specified file' do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'custom/my_contracts.rb')
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, contracts_content)
          Dir.chdir(dir)

          expect { described_class.run(['--file', path]) }.to output(/REQUEST MODELS/).to_stdout
        end
      end
    end
  end

  private

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
