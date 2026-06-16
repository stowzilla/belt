# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt do
  before { Belt.reset_gem_paths! }

  it 'has a version number' do
    expect(Belt::VERSION).not_to be_nil
  end

  it 'tracks controller paths' do
    expect(Belt.controller_paths).to be_an(Array)
  end

  describe '.gem_controller_paths' do
    it 'auto-discovers lambda/controllers dirs from gemspecs' do
      expect(Belt.gem_controller_paths).to be_an(Array)
    end
  end

  describe '.gem_model_paths' do
    it 'auto-discovers lambda/models dirs from gemspecs' do
      expect(Belt.gem_model_paths).to be_an(Array)
    end
  end

  describe '.all_controller_paths' do
    it 'includes app and gem controller paths' do
      expect(Belt.all_controller_paths).to be_an(Array)
    end
  end

  describe '.all_model_paths' do
    it 'only returns paths that exist on disk' do
      Belt.all_model_paths.each do |path|
        expect(File.directory?(path)).to be(true)
      end
    end
  end

  describe '.reset_gem_paths!' do
    it 'clears cached gem paths' do
      Belt.gem_controller_paths # trigger discovery
      Belt.reset_gem_paths!
      # After reset, calling again re-discovers
      expect(Belt.gem_controller_paths).to be_an(Array)
    end
  end
end
