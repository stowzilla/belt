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

  describe 'Cognito identity re-anchoring' do
    def list_tables(source:, dest:)
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'prod-readonly')
                                        .and_return(aws_success('TableNames' => source))
      allow(Open3).to receive(:capture2).with('aws', 'dynamodb', 'list-tables', '--output', 'json',
                                              '--profile', 'dev')
                                        .and_return(aws_success('TableNames' => dest))
    end

    before do
      # source + destination both have users and memberships tables
      list_tables(source: %w[myapp-prod-users myapp-prod-memberships],
                  dest: %w[myapp-dev-users myapp-dev-memberships])

      # destination memberships table is empty (eligible to copy)
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-dev-memberships',
        '--select', 'COUNT', '--limit', '1', '--output', 'json', '--profile', 'dev'
      ).and_return(aws_success('Count' => 0))

      # destination users table — the authoritative email → dev-sub map
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-dev-users', '--output', 'json', '--profile', 'dev'
      ).and_return(aws_success('Items' => [
                                 { 'id' => { 'S' => 'dev-sub-andy' }, 'email' => { 'S' => 'andy@example.com' } }
                               ]))

      # source memberships: one for andy (should re-anchor), one for an
      # invitee with no destination user yet (stale sub should be cleared)
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-prod-memberships', '--output', 'json',
        '--profile', 'prod-readonly'
      ).and_return(aws_success('Items' => [
                                 { 'id' => { 'S' => 'm1' }, 'email' => { 'S' => 'andy@example.com' },
                                   'cognito_sub' => { 'S' => 'prod-sub-andy' } },
                                 { 'id' => { 'S' => 'm2' }, 'email' => { 'S' => 'newbie@example.com' },
                                   'cognito_sub' => { 'S' => 'prod-sub-newbie' } }
                               ]))
    end

    it 're-anchors matching cognito_sub, clears unmatched, and skips the users table' do
      written = nil
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'batch-write-item', '--request-items', instance_of(String), '--output', 'json',
        '--profile', 'dev'
      ) do |*args|
        written = JSON.parse(File.read(args[4].delete_prefix('file://')))
        aws_success({})
      end

      expect { copier.run }.to output(/skip  users .*authoritative/).to_stdout

      items = written.fetch('myapp-dev-memberships').map { |req| req.fetch('PutRequest').fetch('Item') }
      andy = items.find { |i| i.dig('email', 'S') == 'andy@example.com' }
      newbie = items.find { |i| i.dig('email', 'S') == 'newbie@example.com' }

      expect(andy.dig('cognito_sub', 'S')).to eq('dev-sub-andy') # re-anchored to the dev pool
      expect(newbie).not_to have_key('cognito_sub')              # stale sub cleared
    end

    it 'copies cognito_sub verbatim when remap_identity is false' do
      verbatim = described_class.new(
        from_prefixes: ['myapp-prod-'], to_prefixes: ['myapp-dev-'],
        from_profile: 'prod-readonly', to_profile: 'dev', remap_identity: false
      )

      # with remap off, the users table is copied like any other, so the dest
      # users COUNT check is what gates it
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-dev-users',
        '--select', 'COUNT', '--limit', '1', '--output', 'json', '--profile', 'dev'
      ).and_return(aws_success('Count' => 0))
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'scan', '--table-name', 'myapp-prod-users', '--output', 'json', '--profile', 'prod-readonly'
      ).and_return(aws_success('Items' => [{ 'id' => { 'S' => 'prod-sub-andy' },
                                             'email' => { 'S' => 'andy@example.com' } }]))

      writes = []
      allow(Open3).to receive(:capture2).with(
        'aws', 'dynamodb', 'batch-write-item', '--request-items', instance_of(String), '--output', 'json',
        '--profile', 'dev'
      ) do |*args|
        writes << JSON.parse(File.read(args[4].delete_prefix('file://')))
        aws_success({})
      end

      verbatim.run

      membership_write = writes.find { |w| w.key?('myapp-dev-memberships') }
      subs = membership_write.fetch('myapp-dev-memberships')
                             .map { |req| req.dig('PutRequest', 'Item', 'cognito_sub', 'S') }
      expect(subs).to contain_exactly('prod-sub-andy', 'prod-sub-newbie')
    end
  end
end
