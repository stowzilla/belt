# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/doctor_command'

RSpec.describe Belt::CLI::DoctorCommand do
  subject(:command) { described_class.new }

  describe '#extract_expected_indexes (private)' do
    def extract(model_source)
      command.send(:extract_expected_indexes, model_source)
    end

    it 'expects a convention {Assoc}Index for a plain belongs_to' do
      indexes = extract(<<~RUBY)
        class Epic < ApplicationRecord
          belongs_to :project
        end
      RUBY

      expect(indexes).to eq([{ name: 'ProjectIndex', association: 'project' }])
    end

    it 'skips associations that opt out with index: false' do
      indexes = extract(<<~RUBY)
        class Evidence < ApplicationRecord
          belongs_to :project, index: false
        end
      RUBY

      expect(indexes).to be_empty
    end

    it 'honours an explicit index: name over the convention' do
      indexes = extract(<<~RUBY)
        class ApiKey < ApplicationRecord
          belongs_to :project, index: 'ProjectNameIndex'
        end
      RUBY

      expect(indexes).to eq([{ name: 'ProjectNameIndex', association: 'project' }])
    end

    it 'does not demand a phantom index for a foreign_key-remapped, opted-out belongs_to' do
      # membership.rb: belongs_to :user maps to cognito_sub and opts out; CognitoIndex covers it.
      indexes = extract(<<~RUBY)
        class Membership < ApplicationRecord
          belongs_to :user, foreign_key: 'cognito_sub', optional: true, index: false
        end
      RUBY

      expect(indexes).to be_empty
    end

    it 'ignores belongs_to lines inside comments' do
      indexes = extract(<<~RUBY)
        class Thing < ApplicationRecord
          # belongs_to :project  (documented, not declared)
          belongs_to :owner
        end
      RUBY

      expect(indexes).to eq([{ name: 'OwnerIndex', association: 'owner' }])
    end

    it 'handles a mix of required, opted-out, and overridden associations' do
      indexes = extract(<<~RUBY)
        class Widget < ApplicationRecord
          belongs_to :project
          belongs_to :account, index: false
          belongs_to :region, index: 'RegionCodeIndex'
        end
      RUBY

      expect(indexes).to contain_exactly(
        { name: 'ProjectIndex', association: 'project' },
        { name: 'RegionCodeIndex', association: 'region' }
      )
    end

    it 'agrees with the generator on which indexes exist' do
      # The doctor preflight and the table generator must never disagree about a
      # model, or `belt setup tables` → `belt deploy` loops. Both skip index: false.
      require 'belt/cli/tables_command'
      generator = Belt::CLI::TablesCommand.new(quiet: true)

      source = <<~RUBY
        class Membership < ApplicationRecord
          belongs_to :project
          belongs_to :user, foreign_key: 'cognito_sub', index: false
        end
      RUBY

      expected = extract(source).map { |i| i[:name] }.sort
      generated = generator.send(:extract_belongs_to_indexes, source).map { |i| i[:name] }.sort

      expect(expected).to eq(generated)
    end
  end
end
