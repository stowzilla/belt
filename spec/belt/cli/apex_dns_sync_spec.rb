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
end
