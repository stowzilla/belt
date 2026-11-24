# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/acm_pending_validation'

RSpec.describe Belt::CLI::AcmPendingValidation do
  let(:ok) { instance_double(Process::Status, success?: true) }
  let(:failed) { instance_double(Process::Status, success?: false) }
  let(:arn) { 'arn:aws:acm:us-east-1:000000000000:certificate/abc' }

  let(:list_json) do
    JSON.generate('CertificateSummaryList' => [
                    { 'DomainName' => 'example.com', 'CertificateArn' => arn },
                    { 'DomainName' => 'dev.example.com', 'CertificateArn' => 'arn:other' }
                  ])
  end

  let(:record) { { 'Name' => '_abc.example.com.', 'Type' => 'CNAME', 'Value' => '_xyz.acm-validations.aws.' } }

  let(:describe_json) do
    JSON.generate('Certificate' => { 'DomainValidationOptions' => [
                    { 'DomainName' => 'example.com', 'ValidationMethod' => 'DNS',
                      'ValidationStatus' => 'PENDING_VALIDATION', 'ResourceRecord' => record },
                    { 'DomainName' => '*.example.com', 'ValidationMethod' => 'DNS',
                      'ValidationStatus' => 'PENDING_VALIDATION', 'ResourceRecord' => record }
                  ] })
  end

  it 'returns one record for the apex and wildcard, from pending certs on that domain only' do
    allow(Open3).to receive(:capture2e) do |_env, *cmd|
      case cmd[0..2]
      when %w[aws acm list-certificates] then [list_json, ok]
      when %w[aws acm describe-certificate]
        expect(cmd).to include(arn)
        [describe_json, ok]
      end
    end

    expect(described_class.records('example.com', 'AWS_PROFILE' => 'p')).to eq(
      [{ name: '_abc.example.com.', type: 'CNAME', value: '_xyz.acm-validations.aws.' }]
    )
  end

  it 'looks in us-east-1, where the CloudFront cert lives' do
    allow(Open3).to receive(:capture2e).and_return([list_json, ok])
    described_class.pending_cert_arns('example.com', {})

    expect(Open3).to have_received(:capture2e).with({}, 'aws', 'acm', 'list-certificates', '--region', 'us-east-1',
                                                    '--certificate-statuses', 'PENDING_VALIDATION', '--output', 'json')
  end

  it 'skips options ACM has not filled in yet' do
    pending_json = JSON.generate('Certificate' => { 'DomainValidationOptions' => [
                                   { 'ValidationMethod' => 'DNS', 'ValidationStatus' => 'PENDING_VALIDATION' }
                                 ] })
    allow(Open3).to receive(:capture2e).and_return([pending_json, ok])

    expect(described_class.validation_records(arn, {})).to eq([])
  end

  it 'returns [] when AWS fails' do
    allow(Open3).to receive(:capture2e).and_return(['expired token', failed])

    expect(described_class.records('example.com')).to eq([])
  end

  it 'returns [] without calling AWS when there is no domain' do
    allow(Open3).to receive(:capture2e)

    expect(described_class.records(nil)).to eq([])
    expect(Open3).not_to have_received(:capture2e)
  end
end
