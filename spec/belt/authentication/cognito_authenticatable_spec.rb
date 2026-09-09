# frozen_string_literal: true

require 'spec_helper'

# Models declared once at load: `cognito_authenticatable` is a class-body macro, and
# these specs are about what it installs.
class SpecAuthUser < ActiveItem::Base
  cognito_authenticatable
end

# Declares its own schema *after* the macro — the order that would clobber the
# identity GSI if the macro merely assigned it.
class SpecAuthLateSchemaUser < ActiveItem::Base
  cognito_authenticatable
  indexes('OrgIndex' => { partition_key: 'org_id' })
  dynamo_attribute_map('org_id' => 'orgId')
  attr_accessor :org_id
end

class SpecAuthStaffUser < ActiveItem::Base
  cognito_authenticatable roles: %w[member admin support], default_role: 'support', email_index: false
end

RSpec.describe Belt::Authentication::CognitoAuthenticatable do
  describe 'the schema it installs' do
    it 'adds an EmailIndex GSI' do
      expect(SpecAuthUser.indexes).to include('EmailIndex' => { partition_key: 'email' })
    end

    it 'keeps identity attributes snake_case in DynamoDB' do
      expect(SpecAuthUser.dynamo_attribute_map).to include(
        'email' => 'email', 'email_verified' => 'email_verified', 'last_seen_on' => 'last_seen_on'
      )
    end

    it 'defines the identity attributes' do
      expect(SpecAuthUser.attribute_names).to include('email', 'name', 'role', 'email_verified', 'last_seen_on')
    end

    it 'survives a model declaring its own indexes afterwards' do
      expect(SpecAuthLateSchemaUser.indexes.keys).to include('EmailIndex', 'OrgIndex')
    end

    it 'survives a model declaring its own attribute map afterwards' do
      expect(SpecAuthLateSchemaUser.dynamo_attribute_map).to include('email' => 'email', 'org_id' => 'orgId')
    end

    it 'omits the GSI when email_index is false' do
      expect(SpecAuthStaffUser.indexes.keys).not_to include('EmailIndex')
    end
  end

  describe 'roles' do
    it 'validates role against the declared list' do
      expect(SpecAuthUser.new(role: 'admin')).to be_valid
      expect(SpecAuthUser.new(role: 'pirate')).not_to be_valid
    end

    it 'accepts a custom role list' do
      expect(SpecAuthStaffUser.new(role: 'support')).to be_valid
      expect(SpecAuthStaffUser.cognito_default_role).to eq('support')
    end

    it 'rejects a default_role that is not in roles' do
      expect { Class.new(ActiveItem::Base) { cognito_authenticatable default_role: 'boss' } }
        .to raise_error(ArgumentError, /not in roles/)
    end

    it 'reports staff via #admin?' do
      expect(SpecAuthUser.new(role: 'admin')).to be_admin
      expect(SpecAuthUser.new(role: 'member')).not_to be_admin
    end
  end

  describe '#email_verified?' do
    it 'accepts the flattened string form API Gateway produces' do
      expect(SpecAuthUser.new(email_verified: 'true')).to be_email_verified
      expect(SpecAuthUser.new(email_verified: true)).to be_email_verified
      expect(SpecAuthUser.new(email_verified: nil)).not_to be_email_verified
    end
  end

  describe '.for_sub' do
    it 'returns nil instead of raising when the user does not exist' do
      allow(SpecAuthUser).to receive(:find).and_raise(ActiveItem::RecordNotFound)

      expect(SpecAuthUser.for_sub('nope')).to be_nil
    end

    it 'does not go to the database for a blank sub' do
      expect(SpecAuthUser).not_to receive(:find)

      expect(SpecAuthUser.for_sub('')).to be_nil
      expect(SpecAuthUser.for_sub(nil)).to be_nil
    end
  end

  describe '.sync_from_claims!' do
    let(:created) { [] }

    before do
      allow(SpecAuthUser).to receive(:find).and_raise(ActiveItem::RecordNotFound)
      allow(SpecAuthUser).to receive(:create!) do |attrs|
        created << attrs
        SpecAuthUser.new(attrs)
      end
    end

    it 'provisions a row keyed by the Cognito sub' do
      user = SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'Ada@Example.com ', name: 'Ada')

      expect(created.first).to include(id: 'sub-1', email: 'ada@example.com', name: 'Ada', role: 'member')
      expect(user.id).to eq('sub-1')
    end

    it 'falls back to the email local part when Cognito sends no name' do
      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com')

      expect(created.first[:name]).to eq('ada')
    end

    it 'mirrors the staff group onto role' do
      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com', admin: true)

      expect(created.first[:role]).to eq('admin')
    end

    it 'stamps last_seen_on as a date, not a timestamp' do
      SpecAuthUser.sync_from_claims!(sub: 'sub-1')

      expect(created.first[:last_seen_on]).to eq(Time.now.utc.strftime('%Y-%m-%d'))
    end

    it 'is a no-op without a sub' do
      expect(SpecAuthUser.sync_from_claims!(sub: nil)).to be_nil
      expect(SpecAuthUser.sync_from_claims!(sub: '')).to be_nil
      expect(created).to be_empty
    end

    # Two concurrent first requests: the conditional put loses, and the row we wanted
    # now exists.
    it 'recovers when a concurrent request provisioned the same user' do
      winner = SpecAuthUser.new(id: 'sub-1', role: 'member')
      lookups = 0
      allow(SpecAuthUser).to receive(:find) do
        lookups += 1
        raise ActiveItem::RecordNotFound if lookups == 1

        winner
      end
      allow(SpecAuthUser).to receive(:create!).and_raise(ActiveItem::RecordInvalid.new(winner))

      expect(SpecAuthUser.sync_from_claims!(sub: 'sub-1')).to eq(winner)
    end
  end

  describe '.sync_from_claims! on an existing user' do
    let(:existing) do
      SpecAuthUser.new(
        id: 'sub-1', email: 'ada@example.com', name: 'Ada', role: 'member',
        email_verified: true, last_seen_on: Time.now.utc.strftime('%Y-%m-%d')
      )
    end

    before { allow(SpecAuthUser).to receive(:find).and_return(existing) }

    # The whole point of the write-averse design: this runs on every authenticated
    # request, so an unchanged user must cost one GetItem and nothing else.
    it 'does not write when nothing drifted' do
      expect(existing).not_to receive(:update!)

      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com', name: 'Ada', email_verified: true)
    end

    it 'writes only the attributes that changed' do
      expect(existing).to receive(:update!).with({ name: 'Ada Lovelace' })

      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com', name: 'Ada Lovelace',
                                     email_verified: true)
    end

    it 'promotes and demotes as the Cognito group changes' do
      expect(existing).to receive(:update!).with({ role: 'admin' })
      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com', name: 'Ada',
                                     email_verified: true, admin: true)

      existing.role = 'admin'
      expect(existing).to receive(:update!).with({ role: 'member' })
      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com', name: 'Ada',
                                     email_verified: true, admin: false)
    end

    it 'runs the after_cognito_sync hook' do
      expect(existing).to receive(:after_cognito_sync)

      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com', name: 'Ada', email_verified: true)
    end

    # An admin who is still an admin must not generate a write. Guards against a
    # regression where role mirroring compares against the wrong side and rewrites
    # 'admin' → 'admin' on every request.
    it 'does not write when an admin stays an admin' do
      existing.role = 'admin'
      expect(existing).not_to receive(:update!)

      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com', name: 'Ada',
                                     email_verified: true, admin: true)
    end

    # last_seen_on is a date, but sync still runs across a day boundary. When the
    # stored date is stale, the drift write includes it — and only it, if nothing
    # else changed.
    it 'writes last_seen_on when the stored date is stale' do
      existing.last_seen_on = '2000-01-01'
      today = Time.now.utc.strftime('%Y-%m-%d')
      expect(existing).to receive(:update!).with({ last_seen_on: today })

      SpecAuthUser.sync_from_claims!(sub: 'sub-1', email: 'ada@example.com', name: 'Ada', email_verified: true)
    end
  end

  describe '.for_email' do
    it 'queries the EmailIndex with a normalized address' do
      expect(SpecAuthUser).to receive(:find_by).with(email: 'ada@example.com', index: 'EmailIndex')

      SpecAuthUser.for_email(' Ada@Example.com ')
    end

    it 'does not query for a blank address' do
      expect(SpecAuthUser).not_to receive(:find_by)

      expect(SpecAuthUser.for_email(nil)).to be_nil
    end

    # A model that opted out of the GSI (email_index: false) still resolves by email —
    # it just does an unindexed find_by rather than an index query. Without this the
    # false branch of #for_email is never exercised.
    it 'does an unindexed lookup when the model has no email index' do
      expect(SpecAuthStaffUser).to receive(:find_by).with(email: 'ada@example.com')
      expect(SpecAuthStaffUser).not_to receive(:find_by).with(hash_including(:index))

      SpecAuthStaffUser.for_email(' Ada@Example.com ')
    end
  end

  describe '.cognito_authenticatable?' do
    it 'is true for a model that declared the macro' do
      expect(SpecAuthUser.cognito_authenticatable?).to be(true)
    end

    it 'is false for a model that did not' do
      plain = Class.new(ActiveItem::Base)

      expect(plain.cognito_authenticatable?).to be(false)
    end
  end
end
