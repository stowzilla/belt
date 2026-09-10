# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt::Authentication::Configuration do
  subject(:config) { described_class.new }

  around do |example|
    original = ENV.to_hash
    example.run
    ENV.replace(original)
  end

  describe '#user_class' do
    it "defaults to 'User'" do
      expect(config.user_class_name).to eq('User')
    end

    it 'accepts a class' do
      config.user_class = String

      expect(config.user_class).to eq(String)
    end

    it 'accepts a name and resolves it lazily' do
      config.user_class = 'Integer'

      expect(config.user_class).to eq(Integer)
    end

    # An app can use the Cognito plumbing without persisting a user row.
    it 'is nil when the constant does not exist' do
      config.user_class = 'NoSuchModel'

      expect(config.user_class).to be_nil
    end
  end

  describe '#admin_groups' do
    it "defaults to ['admins']" do
      expect(config.admin_groups).to eq(%w[admins])
    end

    it 'reads ADMIN_COGNITO_GROUPS' do
      ENV['ADMIN_COGNITO_GROUPS'] = 'staff, platform_admins'

      expect(config.admin_groups).to eq(%w[staff platform_admins])
    end

    it 'prefers an explicit setting over the environment' do
      ENV['ADMIN_COGNITO_GROUPS'] = 'staff'
      config.admin_groups = %w[owners]

      expect(config.admin_groups).to eq(%w[owners])
    end
  end

  describe '#issuer' do
    it 'is nil without a user pool, which disables the issuer check' do
      ENV.delete('COGNITO_USER_POOL_ID')

      expect(config.issuer).to be_nil
    end

    it 'derives from the Cognito environment variables' do
      ENV['COGNITO_USER_POOL_ID'] = 'us-east-1_abc'
      ENV['COGNITO_REGION'] = 'us-east-2'

      expect(config.issuer).to eq('https://cognito-idp.us-east-2.amazonaws.com/us-east-1_abc')
    end

    it 'can be set explicitly' do
      config.issuer = 'https://example.com'

      expect(config.issuer).to eq('https://example.com')
    end
  end
end
