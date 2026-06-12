# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt do
  it 'has a version number' do
    expect(Belt::VERSION).not_to be_nil
  end

  it 'tracks controller paths' do
    expect(Belt.controller_paths).to be_an(Array)
  end

  it 'tracks holsters' do
    expect(Belt.holsters).to be_an(Array)
  end
end
