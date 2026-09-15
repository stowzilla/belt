# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'belt/cli/dynamo_copier'

RSpec.describe Belt::CLI::DynamoCopier do
  def aws_success(json)
    [JSON.generate(json), instance_double(Process::Status, success?: true)]
  end

  def aws_failure
    ['', instance_double(Process::Status, success?: false)]
  end

  subject(:copier) do
    described_class.new(
      from_prefixes: ['myapp-prod-'],
      to_prefixes: ['myapp-dev-'],
      from_profile: 'prod-readonly',
      to_profile: 'dev'
    )
  end

  describe '#run' do
    it 'reports nothing to copy when no tables match either prefix' do
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'prod-readonly')
                                        .and_return(aws_success('TableNames' => []))
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'dev')
                                        .and_return(aws_success('TableNames' => []))

      expect { expect(copier.run).to be true }.to output(/No matching DynamoDB tables/).to_stdout
    end

    it 'copies items from source into an empty destination table' do
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'prod-readonly')
                                        .and_return(aws_success('TableNames' => ['myapp-prod-posts']))
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'dev')
                                        .and_return(aws_success('TableNames' => ['myapp-dev-posts']))

      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-dev-posts',
        '--select', 'COUNT', '--limit', '1', '--output', 'json', '--profile', 'dev'
      ).and_return(aws_success('Count' => 0))

      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-prod-posts', '--output', 'json',
        '--profile', 'prod-readonly'
      ).and_return(aws_success('Items' => [{ 'id' => { 'S' => '1' } }]))

      expect(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'batch-write-item', '--request-items', instance_of(String),
        '--output', 'json', '--profile', 'dev'
      ).and_return(aws_success({}))

      result = nil
      expect { result = copier.run }.to output(/copy  posts \(1 item\)/).to_stdout
      expect(result).to be true
    end

    it 'skips a destination table that already has data' do
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'prod-readonly')
                                        .and_return(aws_success('TableNames' => ['myapp-prod-posts']))
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'dev')
                                        .and_return(aws_success('TableNames' => ['myapp-dev-posts']))
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-dev-posts',
        '--select', 'COUNT', '--limit', '1', '--output', 'json', '--profile', 'dev'
      ).and_return(aws_success('Count' => 3))

      expect(Open3).not_to receive(:capture2).with('aws', 'dynamodb', 'batch-write-item', any_args)

      expect { copier.run }.to output(/skip  posts \(already has data\)/).to_stdout
    end

    it 'overwrites a non-empty destination table when force is true' do
      forced = described_class.new(
        from_prefixes: ['myapp-prod-'],
        to_prefixes: ['myapp-dev-'],
        from_profile: 'prod-readonly',
        to_profile: 'dev',
        force: true
      )

      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'prod-readonly')
                                        .and_return(aws_success('TableNames' => ['myapp-prod-posts']))
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'dev')
                                        .and_return(aws_success('TableNames' => ['myapp-dev-posts']))

      # existing destination item to be wiped
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-dev-posts', '--output', 'json', '--profile', 'dev'
      ).and_return(aws_success('Items' => [{ 'id' => { 'S' => 'old' } }]))
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'describe-table', '--table-name', 'myapp-dev-posts', '--output', 'json', '--profile', 'dev'
      ).and_return(aws_success('Table' => { 'KeySchema' => [{ 'AttributeName' => 'id' }] }))

      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-prod-posts', '--output', 'json',
        '--profile', 'prod-readonly'
      ).and_return(aws_success('Items' => [{ 'id' => { 'S' => 'new' } }]))

      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'batch-write-item', '--request-items', instance_of(String), '--output', 'json',
        '--profile', 'dev'
      ).and_return(aws_success({}))

      expect { forced.run }.to output(/copy  posts \(1 item\)/).to_stdout
    end

    it 'skips a table missing on the destination side' do
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'prod-readonly')
                                        .and_return(aws_success('TableNames' => ['myapp-prod-posts']))
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'dev')
                                        .and_return(aws_success('TableNames' => []))

      expect { copier.run }.to output(/No matching DynamoDB tables/).to_stdout
    end
  end
end
