# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'belt/cli/dns_command'

RSpec.describe Belt::CLI::DnsCommand do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  describe '#resolve_state_bucket_for_profile' do
    let(:dns_command) { described_class.new }

    before do
      # Set up a sibling environment with a backend.tf
      FileUtils.mkdir_p('infrastructure/dev')
      File.write('infrastructure/dev/backend.tf', <<~TF)
        terraform {
          backend "s3" {
            bucket  = "belt-terraform-state-533906692285"
            key     = "test/dev/terraform.tfstate"
            region  = "us-east-1"
            encrypt = true
          }
        }
      TF
    end

    context 'when profile is explicitly provided' do
      before do
        # Mock the AWS CLI call to return the profile's account ID
        allow(Open3).to receive(:capture2e).with(
          'aws', 'sts', 'get-caller-identity', '--profile', 'fpshared'
        ).and_return(
          ['{"Account": "250621608383", "Arn": "arn:aws:iam::250621608383:user/test"}',
           instance_double(Process::Status, success?: true)]
        )
      end

      it 'derives bucket from the specified profile, ignoring sibling backends' do
        bucket = dns_command.send(:resolve_state_bucket_for_profile, 'fpshared')

        # Should use fpshared's account ID, NOT the sibling's bucket
        expect(bucket).to eq('belt-terraform-state-250621608383')
      end

      it 'does not look at sibling backend.tf files' do
        # Should not read the sibling backend.tf
        expect(File).not_to receive(:read).with('infrastructure/dev/backend.tf')

        dns_command.send(:resolve_state_bucket_for_profile, 'fpshared')
      end
    end

    context 'when profile is nil' do
      it 'falls back to sibling backend.tf bucket' do
        bucket = dns_command.send(:resolve_state_bucket_for_profile, nil)

        expect(bucket).to eq('belt-terraform-state-533906692285')
      end
    end

    context 'when profile is nil and no sibling backend exists' do
      before do
        FileUtils.rm_rf('infrastructure/dev')
        # Mock AWS CLI for current credentials
        allow(Open3).to receive(:capture2e).with(
          'aws', 'sts', 'get-caller-identity'
        ).and_return(
          ['{"Account": "999999999999", "Arn": "arn:aws:iam::999999999999:user/test"}',
           instance_double(Process::Status, success?: true)]
        )
      end

      it 'derives bucket from current AWS credentials' do
        bucket = dns_command.send(:resolve_state_bucket_for_profile, nil)

        expect(bucket).to eq('belt-terraform-state-999999999999')
      end
    end

    context 'when profile AWS call fails' do
      before do
        allow(Open3).to receive(:capture2e).with(
          'aws', 'sts', 'get-caller-identity', '--profile', 'invalid'
        ).and_return(
          ['An error occurred', instance_double(Process::Status, success?: false)]
        )
      end

      it 'returns placeholder bucket' do
        bucket = dns_command.send(:resolve_state_bucket_for_profile, 'invalid')

        expect(bucket).to eq('belt-terraform-state')
      end
    end
  end
end
