# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt do
  it 'has a version number' do
    expect(Belt::VERSION).not_to be_nil
  end

  it 'tracks controller paths' do
    expect(Belt.controller_paths).to be_an(Array)
  end

  it 'tracks gem controller paths' do
    expect(Belt.gem_controller_paths).to be_an(Array)
  end

  describe '.register_controllers' do
    it 'adds a gem controller path' do
      Belt.register_controllers('/tmp/test_gem/lambda/controllers')
      expect(Belt.gem_controller_paths).to include('/tmp/test_gem/lambda/controllers')
    end

    it 'does not add duplicates' do
      Belt.register_controllers('/tmp/dedup_test')
      Belt.register_controllers('/tmp/dedup_test')
      expect(Belt.gem_controller_paths.count('/tmp/dedup_test')).to eq(1)
    end
  end
end
