# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/tables_command'

RSpec.describe Belt::CLI::TablesCommand do
  subject(:command) { described_class.new(quiet: true) }

  describe '#table_name (private)' do
    it 'dasherizes single-word model names' do
      result = command.send(:table_name, 'user')
      expect(result).to eq('${var.app_name}-${var.environment}-users')
    end

    it 'dasherizes multi-word model names' do
      result = command.send(:table_name, 'event_coordinator')
      expect(result).to eq('${var.app_name}-${var.environment}-event-coordinators')
    end

    it 'dasherizes triple-word model names' do
      result = command.send(:table_name, 'user_login_history')
      expect(result).to eq('${var.app_name}-${var.environment}-user-login-histories')
    end

    it 'matches ActiveItem table_name_for convention' do
      # ActiveItem: class_name.underscore.dasherize.pluralize
      # Belt: pluralize(underscore(class_name)).tr('_', '-')
      # Both should produce the same result
      model_name = 'event_coordinator'
      belt_result = command.send(:table_name, model_name)
      # ActiveItem would produce: "event-coordinators" as the base
      expect(belt_result).to include('event-coordinators')
      expect(belt_result).not_to include('event_coordinators')
    end
  end
end
