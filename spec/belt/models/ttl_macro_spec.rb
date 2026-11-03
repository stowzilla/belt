# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt::Models::TtlMacro do
  it 'camelCases a symbol the way ActiveItem stores it' do
    model = Class.new(ActiveItem::Base) { ttl_attribute :expires_at }
    expect(model.ttl_attribute).to eq('expiresAt')
  end

  it 'uses a string verbatim' do
    model = Class.new(ActiveItem::Base) { ttl_attribute 'expires_at_epoch' }
    expect(model.ttl_attribute).to eq('expires_at_epoch')
  end

  it 'is nil when undeclared' do
    expect(Class.new(ActiveItem::Base).ttl_attribute).to be_nil
  end
end
