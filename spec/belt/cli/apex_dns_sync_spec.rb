# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/apex_dns_sync'

RSpec.describe Belt::CLI::ApexDnsSync do
  # ApexDnsSync#initialize reads config from disk; for these pure-logic checks we
  # skip the constructor and exercise the record-building helpers directly.
  subject(:sync) { described_class.allocate }

  describe '#build_dkim_changes' do
    let(:domain) { 'featureparity.dev' }
    let(:tokens) { %w[aaa111 bbb222 ccc333] }

    it 'builds one UPSERT CNAME per DKIM token pointing at amazonses.com' do
      changes = sync.send(:build_dkim_changes, domain, tokens)

      expect(changes.size).to eq(3)
      changes.each { |c| expect(c[:Action]).to eq('UPSERT') }

      first = changes.first[:ResourceRecordSet]
      expect(first[:Name]).to eq('aaa111._domainkey.featureparity.dev')
      expect(first[:Type]).to eq('CNAME')
      expect(first[:TTL]).to eq(300)
      expect(first[:ResourceRecords]).to eq([{ Value: 'aaa111.dkim.amazonses.com' }])
    end

    it 'returns no changes when there are no tokens' do
      expect(sync.send(:build_dkim_changes, domain, [])).to eq([])
    end
  end

  describe '#fetch_dkim_tokens' do
    let(:sync) do
      s = described_class.allocate
      s.instance_variable_set(:@env_config, nil)
      s
    end

    it 'returns the tokens from a successful SES get-email-identity call' do
      ses_json = JSON.generate('DkimAttributes' => { 'Tokens' => %w[t1 t2 t3] })
      ok = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return([ses_json, ok])

      expect(sync.send(:fetch_dkim_tokens, 'featureparity.dev')).to eq(%w[t1 t2 t3])
    end

    it 'returns an empty array when SES has no identity for the domain' do
      failed = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture2e).and_return(['not found', failed])

      expect(sync.send(:fetch_dkim_tokens, 'featureparity.dev')).to eq([])
    end
  end

  describe '#extract_cloudfront_target' do
    it 'treats an empty cloudfront_domain_name output as missing' do
      targets = {}
      sync.send(:extract_cloudfront_target, { 'cloudfront_domain_name' => { 'value' => '' } }, targets)
      expect(targets).not_to have_key(:cloudfront)
    end
  end

  describe '#warn_missing_cloudfront_output' do
    let(:sync) do
      s = described_class.allocate
      s.instance_variable_set(:@env, 'prod')
      s.instance_variable_set(:@quiet, false)
      s.instance_variable_set(:@dns_config, nil)
      s
    end

    it 'names the domain left without an A record' do
      expect { sync.send(:warn_missing_cloudfront_output, 'app.example.com') }
        .to output(/app\.example\.com has no A record/).to_stdout
    end
  end

  describe '#while_applying' do
    let(:sync) do
      s = described_class.allocate
      s.instance_variable_set(:@env_config, nil)
      s.instance_variable_set(:@dns_config, nil)
      s.instance_variable_set(:@quiet, true)
      s
    end

    let(:record) { { name: '_abc.example.com.', type: 'CNAME', value: '_xyz.acm-validations.aws.' } }

    before { stub_const("#{described_class}::ACM_WATCH_INTERVAL", 0.01) }

    it 'just runs the block for non-apex envs' do
      allow(sync).to receive(:needs_sync?).and_return(false)
      allow(Belt::CLI::AcmPendingValidation).to receive(:records)

      expect(sync.while_applying { :applied }).to eq(:applied)
      expect(Belt::CLI::AcmPendingValidation).not_to have_received(:records)
    end

    it 'publishes the pending validation CNAME to the root zone once, while the block runs' do
      allow(sync).to receive_messages(needs_sync?: true, env_tfvars_domain: 'example.com', fetch_root_zone_id: 'Z123')
      allow(Belt::CLI::AcmPendingValidation).to receive(:records).with('example.com', {}).and_return([record])
      upserts = Queue.new
      allow(sync).to receive(:upsert_validation_cnames) do |zone, changes|
        upserts << [zone, changes]
        true
      end

      result = sync.while_applying do
        upserts.pop(timeout: 2).tap { sleep 0.05 } # let the watcher poll a few more times
      end

      zone, changes = result
      expect(zone).to eq('Z123')
      expect(changes).to eq([{ Action: 'UPSERT',
                               ResourceRecordSet: { Name: '_abc.example.com.', Type: 'CNAME', TTL: 300,
                                                    ResourceRecords: [{ Value: '_xyz.acm-validations.aws.' }] } }])
      expect(sync).to have_received(:upsert_validation_cnames).once
    end

    it 'keeps polling until ACM has a record, and stops when the block returns' do
      allow(sync).to receive_messages(needs_sync?: true, env_tfvars_domain: 'example.com', fetch_root_zone_id: 'Z123')
      calls = 0
      allow(Belt::CLI::AcmPendingValidation).to receive(:records) { (calls += 1) < 3 ? [] : [record] }
      published = Queue.new
      allow(sync).to receive(:upsert_validation_cnames) { published << true }

      sync.while_applying { published.pop(timeout: 2) }

      expect(calls).to be >= 3
      expect(sync).to have_received(:upsert_validation_cnames).once
    end

    it 'does not watch when the root zone ID is unavailable' do
      allow(sync).to receive_messages(needs_sync?: true, env_tfvars_domain: 'example.com', fetch_root_zone_id: nil)
      allow(Belt::CLI::AcmPendingValidation).to receive(:records)

      sync.while_applying { :applied }

      expect(Belt::CLI::AcmPendingValidation).not_to have_received(:records)
    end
  end
end
