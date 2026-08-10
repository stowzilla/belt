# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe 'Belt.root' do
  around do |example|
    Belt.root = nil
    original_dir = Dir.pwd
    example.run
  ensure
    Dir.chdir(original_dir)
    Belt.root = nil
  end

  context 'when config/routes.rb exists in the current directory' do
    it 'returns the current directory' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.rb'))
        Dir.chdir(dir)

        expect(Belt.root).to eq(dir)
      end
    end
  end

  context 'when config/routes.tf.rb exists (legacy)' do
    it 'returns the current directory' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.root).to eq(dir)
      end
    end
  end

  context 'when infrastructure/routes.tf.rb exists (legacy)' do
    it 'returns the current directory' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'infrastructure'))
        FileUtils.touch(File.join(dir, 'infrastructure/routes.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.root).to eq(dir)
      end
    end
  end

  context 'when running from a subdirectory of the project' do
    it 'walks up to find the project root (config/routes.rb)' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.rb'))
        subdir = File.join(dir, 'lambda', 'lib')
        FileUtils.mkdir_p(subdir)
        Dir.chdir(subdir)

        expect(Belt.root).to eq(dir)
      end
    end

    it 'walks up to find the project root (config/routes.tf.rb legacy)' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.tf.rb'))
        subdir = File.join(dir, 'lambda', 'lib')
        FileUtils.mkdir_p(subdir)
        Dir.chdir(subdir)

        expect(Belt.root).to eq(dir)
      end
    end

    it 'walks up to find the project root (infrastructure/ legacy)' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'infrastructure'))
        FileUtils.touch(File.join(dir, 'infrastructure/routes.tf.rb'))
        subdir = File.join(dir, 'lambda', 'lib')
        FileUtils.mkdir_p(subdir)
        Dir.chdir(subdir)

        expect(Belt.root).to eq(dir)
      end
    end
  end

  context 'when no routes file exists anywhere' do
    it 'returns nil' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir)

        expect(Belt.root).to be_nil
      end
    end
  end

  context 'when Belt.root is explicitly set' do
    it 'uses the assigned value' do
      Belt.root = '/custom/path'

      expect(Belt.root).to eq('/custom/path')
    end
  end

  describe '.routes_file' do
    it 'prefers config/routes.rb over legacy paths' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.rb'))
        FileUtils.touch(File.join(dir, 'config/routes.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.routes_file).to eq(File.join(dir, 'config/routes.rb'))
      end
    end

    it 'falls back to config/routes.tf.rb when routes.rb does not exist' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.routes_file).to eq(File.join(dir, 'config/routes.tf.rb'))
      end
    end

    it 'falls back to infrastructure/routes.tf.rb when config/ does not exist' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'infrastructure'))
        FileUtils.touch(File.join(dir, 'infrastructure/routes.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.routes_file).to eq(File.join(dir, 'infrastructure/routes.tf.rb'))
      end
    end
  end

  describe '.contracts_file' do
    it 'prefers config/contracts.rb over legacy paths' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.rb'))
        FileUtils.touch(File.join(dir, 'config/contracts.rb'))
        FileUtils.touch(File.join(dir, 'config/schema.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.contracts_file).to eq(File.join(dir, 'config/contracts.rb'))
      end
    end

    it 'falls back to config/contracts.tf.rb' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.rb'))
        FileUtils.touch(File.join(dir, 'config/contracts.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.contracts_file).to eq(File.join(dir, 'config/contracts.tf.rb'))
      end
    end

    it 'falls back to config/schema.tf.rb' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.rb'))
        FileUtils.touch(File.join(dir, 'config/schema.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.contracts_file).to eq(File.join(dir, 'config/schema.tf.rb'))
      end
    end

    it 'falls back to infrastructure/schema.tf.rb' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.rb'))
        FileUtils.mkdir_p(File.join(dir, 'infrastructure'))
        FileUtils.touch(File.join(dir, 'infrastructure/schema.tf.rb'))
        Dir.chdir(dir)

        expect(Belt.contracts_file).to eq(File.join(dir, 'infrastructure/schema.tf.rb'))
      end
    end
  end

  describe '.schema_file' do
    it 'is an alias for contracts_file' do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config/routes.rb'))
        FileUtils.touch(File.join(dir, 'config/contracts.rb'))
        Dir.chdir(dir)

        expect(Belt.schema_file).to eq(Belt.contracts_file)
      end
    end
  end
end
