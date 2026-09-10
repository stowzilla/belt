# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/environment_config'

RSpec.describe Belt::CLI::EnvironmentConfig do
  describe '#apply!' do
    let(:config) { described_class.new }

    before do
      # Capture original env state
      @original_profile = ENV.fetch('AWS_PROFILE', nil)
      @original_key = ENV.fetch('AWS_ACCESS_KEY_ID', nil)
      @original_secret = ENV.fetch('AWS_SECRET_ACCESS_KEY', nil)

      # Clear env
      ENV.delete('AWS_PROFILE')
      ENV.delete('AWS_ACCESS_KEY_ID')
      ENV.delete('AWS_SECRET_ACCESS_KEY')
    end

    after do
      # Restore original env state
      ENV.delete('AWS_PROFILE')
      ENV.delete('AWS_ACCESS_KEY_ID')
      ENV.delete('AWS_SECRET_ACCESS_KEY')

      ENV['AWS_PROFILE'] = @original_profile if @original_profile
      ENV['AWS_ACCESS_KEY_ID'] = @original_key if @original_key
      ENV['AWS_SECRET_ACCESS_KEY'] = @original_secret if @original_secret
    end

    context 'when aws_profile is set and no credentials in env' do
      before do
        config.instance_variable_set(:@aws_profile, 'myprofile')
      end

      it 'sets AWS_PROFILE' do
        config.apply!
        expect(ENV.fetch('AWS_PROFILE', nil)).to eq('myprofile')
      end
    end

    context 'when aws_profile is set but credentials already in env (CI/OIDC)' do
      before do
        config.instance_variable_set(:@aws_profile, 'myprofile')
        ENV['AWS_ACCESS_KEY_ID'] = 'AKIAIOSFODNN7EXAMPLE'
        ENV['AWS_SECRET_ACCESS_KEY'] = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      end

      it 'does NOT set AWS_PROFILE (preserves OIDC credentials)' do
        config.apply!
        expect(ENV.fetch('AWS_PROFILE', nil)).to be_nil
      end
    end

    context 'when aws_profile is not set' do
      it 'does not set AWS_PROFILE' do
        config.apply!
        expect(ENV.fetch('AWS_PROFILE', nil)).to be_nil
      end
    end

    context 'when env_vars are configured' do
      before do
        config.instance_variable_set(:@env_vars, { 'CUSTOM_VAR' => 'value123' })
      end

      after do
        ENV.delete('CUSTOM_VAR')
      end

      it 'sets the env vars' do
        config.apply!
        expect(ENV.fetch('CUSTOM_VAR', nil)).to eq('value123')
      end
    end
  end

  describe '#credentials_in_env?' do
    let(:config) { described_class.new }

    before do
      @original_key = ENV.fetch('AWS_ACCESS_KEY_ID', nil)
      @original_secret = ENV.fetch('AWS_SECRET_ACCESS_KEY', nil)
      ENV.delete('AWS_ACCESS_KEY_ID')
      ENV.delete('AWS_SECRET_ACCESS_KEY')
    end

    after do
      ENV.delete('AWS_ACCESS_KEY_ID')
      ENV.delete('AWS_SECRET_ACCESS_KEY')
      ENV['AWS_ACCESS_KEY_ID'] = @original_key if @original_key
      ENV['AWS_SECRET_ACCESS_KEY'] = @original_secret if @original_secret
    end

    it 'returns false when neither key is set' do
      expect(config.credentials_in_env?).to be false
    end

    it 'returns false when only key is set' do
      ENV['AWS_ACCESS_KEY_ID'] = 'AKIAIOSFODNN7EXAMPLE'
      expect(config.credentials_in_env?).to be false
    end

    it 'returns false when only secret is set' do
      ENV['AWS_SECRET_ACCESS_KEY'] = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      expect(config.credentials_in_env?).to be false
    end

    it 'returns true when both key and secret are set' do
      ENV['AWS_ACCESS_KEY_ID'] = 'AKIAIOSFODNN7EXAMPLE'
      ENV['AWS_SECRET_ACCESS_KEY'] = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      expect(config.credentials_in_env?).to be true
    end

    it 'returns false when key is empty string' do
      ENV['AWS_ACCESS_KEY_ID'] = ''
      ENV['AWS_SECRET_ACCESS_KEY'] = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      expect(config.credentials_in_env?).to be false
    end
  end
end
