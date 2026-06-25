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

  context 'when infrastructure/routes.tf.rb exists in the current directory' do
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
    it 'walks up to find the project root' do
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
    it 'falls back to pwd' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir)

        expect(Belt.root).to eq(dir)
      end
    end
  end

  context 'when Belt.root is explicitly set' do
    it 'uses the assigned value' do
      Belt.root = '/custom/path'

      expect(Belt.root).to eq('/custom/path')
    end
  end
end
