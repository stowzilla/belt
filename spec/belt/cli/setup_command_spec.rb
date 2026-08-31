# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'belt/cli/setup_command'

RSpec.describe Belt::CLI::SetupCommand do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  describe '#update_backend_config' do
    # Create a minimal setup to test backend config updates
    let(:setup_command) do
      cmd = described_class.new([], quiet: true)
      # Set internal state directly for testing
      cmd.instance_variable_set(:@bucket_name, 'belt-terraform-state-111111111111')
      cmd.instance_variable_set(:@region, 'us-east-1')
      cmd
    end

    before do
      # Set up multiple environment directories with backend.tf files
      %w[dev staging prod].each do |env|
        FileUtils.mkdir_p("infrastructure/#{env}")
        File.write("infrastructure/#{env}/backend.tf", <<~TF)
          terraform {
            backend "s3" {
              bucket  = "belt-terraform-state-original"
              key     = "test/#{env}/terraform.tfstate"
              region  = "us-east-1"
              encrypt = true
            }
          }
        TF
      end
    end

    context 'when @env_name is set' do
      before do
        setup_command.instance_variable_set(:@env_name, 'dev')
      end

      it 'updates only the specified environment backend' do
        setup_command.send(:update_backend_config)

        # dev should be updated
        expect(File.read('infrastructure/dev/backend.tf')).to include('belt-terraform-state-111111111111')

        # staging and prod should be unchanged
        expect(File.read('infrastructure/staging/backend.tf')).to include('belt-terraform-state-original')
        expect(File.read('infrastructure/prod/backend.tf')).to include('belt-terraform-state-original')
      end
    end

    context 'when @env_name is nil and @aws_profile is nil' do
      before do
        setup_command.instance_variable_set(:@env_name, nil)
        setup_command.instance_variable_set(:@aws_profile, nil)
      end

      it 'updates all environment backends' do
        setup_command.send(:update_backend_config)

        %w[dev staging prod].each do |env|
          expect(File.read("infrastructure/#{env}/backend.tf")).to include('belt-terraform-state-111111111111')
        end
      end
    end

    context 'when @env_name is nil but @aws_profile is set' do
      # This is the bug scenario — when belt setup state --aws-profile is called
      # from dns generate, it should NOT update all backends
      before do
        setup_command.instance_variable_set(:@env_name, nil)
        setup_command.instance_variable_set(:@aws_profile, 'fpshared')
      end

      it 'updates all backends (method behavior)' do
        # The method itself still updates all backends when called
        # The fix is in run_state_setup which now skips calling this method
        setup_command.send(:update_backend_config)

        %w[dev staging prod].each do |env|
          expect(File.read("infrastructure/#{env}/backend.tf")).to include('belt-terraform-state-111111111111')
        end
      end
    end
  end

  describe '#run_state_setup' do
    # These tests verify the integration behavior, specifically that
    # --aws-profile prevents updating unrelated backends

    before do
      # Set up multiple environment directories with backend.tf files
      %w[dev staging].each do |env|
        FileUtils.mkdir_p("infrastructure/#{env}")
        File.write("infrastructure/#{env}/backend.tf", <<~TF)
          terraform {
            backend "s3" {
              bucket  = "belt-terraform-state-533906692285"
              key     = "test/#{env}/terraform.tfstate"
              region  = "us-east-1"
              encrypt = true
            }
          }
        TF
      end
    end

    context 'when --aws-profile is passed without env_name' do
      # Stub AWS operations to avoid actual API calls
      let(:setup_command) do
        cmd = described_class.new(['--aws-profile', 'fpshared'], quiet: true)
        cmd
      end

      before do
        # Stub AWS credentials check to return a different account ID
        allow(setup_command).to receive(:aws_configured?).and_return(true)
        setup_command.instance_variable_set(:@aws_account_id, '250621608383')

        # Stub bucket operations
        allow(setup_command).to receive(:bucket_exists?).and_return(true)
        allow(setup_command).to receive(:audit_bucket_security).and_return({
                                                                             versioning: true,
                                                                             encryption: true,
                                                                             public_access_block: true,
                                                                             tls_policy: true
                                                                           })
        allow(setup_command).to receive(:apply_lifecycle)
      end

      it 'does NOT update existing environment backends' do
        setup_command.run_state_setup

        # Both envs should still have the ORIGINAL bucket (533906692285)
        # NOT the new profile's bucket (250621608383)
        expect(File.read('infrastructure/dev/backend.tf')).to include('belt-terraform-state-533906692285')
        expect(File.read('infrastructure/staging/backend.tf')).to include('belt-terraform-state-533906692285')

        # Verify they were NOT updated to the new bucket
        expect(File.read('infrastructure/dev/backend.tf')).not_to include('belt-terraform-state-250621608383')
        expect(File.read('infrastructure/staging/backend.tf')).not_to include('belt-terraform-state-250621608383')
      end
    end

    context 'when env_name is passed (targeted setup)' do
      let(:setup_command) do
        cmd = described_class.new(['dev'], quiet: true)
        cmd
      end

      before do
        allow(setup_command).to receive(:aws_configured?).and_return(true)
        setup_command.instance_variable_set(:@aws_account_id, '999999999999')
        allow(setup_command).to receive(:bucket_exists?).and_return(true)
        allow(setup_command).to receive(:audit_bucket_security).and_return({
                                                                             versioning: true,
                                                                             encryption: true,
                                                                             public_access_block: true,
                                                                             tls_policy: true
                                                                           })
        allow(setup_command).to receive(:apply_lifecycle)
      end

      it 'updates only the specified environment backend' do
        setup_command.run_state_setup

        # dev should be updated
        expect(File.read('infrastructure/dev/backend.tf')).to include('belt-terraform-state-999999999999')

        # staging should be unchanged
        expect(File.read('infrastructure/staging/backend.tf')).to include('belt-terraform-state-533906692285')
      end
    end

    context 'when neither --aws-profile nor env_name is passed (default behavior)' do
      let(:setup_command) do
        cmd = described_class.new([], quiet: true)
        cmd
      end

      before do
        allow(setup_command).to receive(:aws_configured?).and_return(true)
        setup_command.instance_variable_set(:@aws_account_id, '888888888888')
        allow(setup_command).to receive(:bucket_exists?).and_return(true)
        allow(setup_command).to receive(:audit_bucket_security).and_return({
                                                                             versioning: true,
                                                                             encryption: true,
                                                                             public_access_block: true,
                                                                             tls_policy: true
                                                                           })
        allow(setup_command).to receive(:apply_lifecycle)
      end

      it 'updates all environment backends' do
        setup_command.run_state_setup

        %w[dev staging].each do |env|
          expect(File.read("infrastructure/#{env}/backend.tf")).to include('belt-terraform-state-888888888888')
        end
      end
    end
  end
end
