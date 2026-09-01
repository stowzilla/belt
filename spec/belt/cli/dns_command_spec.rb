# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'belt/cli/dns_command'
require 'belt/cli/environment_config'

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

  describe '#show' do
    context 'when infrastructure/dns does not exist' do
      it 'exits with an error' do
        expect do
          described_class.run(['show'])
        end.to raise_error(SystemExit)
      end

      it 'prints a helpful message' do
        expect do
          described_class.run(['show'])
        rescue SystemExit
          # expected
        end.to output(%r{No infrastructure/dns directory found}).to_stdout
      end
    end

    context 'when infrastructure/dns exists' do
      let(:env_config) { instance_double(Belt::CLI::EnvironmentConfig, aws_profile?: false) }

      before do
        FileUtils.mkdir_p('infrastructure/dns')
        File.write('infrastructure/dns/belt.rb', <<~RUBY)
          Belt.configure do |config|
            config.aws_profile = nil
          end
        RUBY
        File.write('infrastructure/dns/terraform.tfvars', <<~TFVARS)
          domain = "example.com"
          environment_zones = {}
        TFVARS

        # Mock EnvironmentConfig.load to avoid BackupConfig dependency
        allow(Belt::CLI::EnvironmentConfig).to receive(:load).with('dns').and_return(env_config)
      end

      context 'when terraform output succeeds' do
        let(:terraform_output) do
          {
            'root_name_servers' => {
              'value' => %w[
                ns-123.awsdns-12.com
                ns-456.awsdns-34.net
                ns-789.awsdns-56.org
                ns-012.awsdns-78.co.uk
              ]
            },
            'root_zone_id' => {
              'value' => 'Z0123456789ABCDEF'
            },
            'delegated_environments' => {
              'value' => %w[dev staging]
            }
          }
        end

        before do
          allow(Open3).to receive(:capture2e)
            .with({}, 'terraform', 'output', '-json')
            .and_return([terraform_output.to_json, double(success?: true)])

          # Mock AWS CLI zone verification - zone exists by default
          allow(Open3).to receive(:capture2e)
            .with('aws', 'route53', 'get-hosted-zone', '--id', 'Z0123456789ABCDEF')
            .and_return(['{}', double(success?: true)])
        end

        it 'displays the name servers' do
          expect do
            described_class.run(['show'])
          end.to output(/ns-123\.awsdns-12\.com/).to_stdout
        end

        it 'displays the domain' do
          expect do
            described_class.run(['show'])
          end.to output(/Domain: example\.com/).to_stdout
        end

        it 'displays the zone ID' do
          expect do
            described_class.run(['show'])
          end.to output(/Zone ID: Z0123456789ABCDEF/).to_stdout
        end

        it 'displays delegated environments' do
          expect do
            described_class.run(['show'])
          end.to output(/Delegated environments: dev, staging/).to_stdout
        end

        context 'when zone does not exist in AWS (stale terraform state)' do
          before do
            allow(Open3).to receive(:capture2e)
              .with('aws', 'route53', 'get-hosted-zone', '--id', 'Z0123456789ABCDEF')
              .and_return(['NoSuchHostedZone', double(success?: false)])
          end

          it 'exits with an error' do
            expect do
              described_class.run(['show'])
            end.to raise_error(SystemExit)
          end

          it 'explains the zone is missing' do
            expect do
              described_class.run(['show'])
            rescue SystemExit
              # expected
            end.to output(/doesn't exist in AWS/).to_stdout
          end

          it 'suggests running belt dns deploy' do
            expect do
              described_class.run(['show'])
            rescue SystemExit
              # expected
            end.to output(/belt dns deploy/).to_stdout
          end
        end
      end

      context 'when terraform output fails' do
        before do
          allow(Open3).to receive(:capture2e)
            .with({}, 'terraform', 'output', '-json')
            .and_return(['Error: No state', double(success?: false)])
        end

        it 'exits with an error' do
          expect do
            described_class.run(['show'])
          end.to raise_error(SystemExit)
        end

        it 'suggests deploying DNS' do
          expect do
            described_class.run(['show'])
          rescue SystemExit
            # expected
          end.to output(/belt dns deploy/).to_stdout
        end
      end
    end
  end

  describe 'subcommand dispatch' do
    it 'recognizes show as a valid subcommand' do
      # Just verify it doesn't print "Unknown dns subcommand"
      expect do
        described_class.run(['show'])
      rescue SystemExit
        # expected - no dns dir
      end.not_to output(/Unknown dns subcommand/).to_stdout
    end

    it 'recognizes list as an alias for show' do
      expect do
        described_class.run(['list'])
      rescue SystemExit
        # expected - no dns dir
      end.not_to output(/Unknown dns subcommand/).to_stdout
    end
  end
end
