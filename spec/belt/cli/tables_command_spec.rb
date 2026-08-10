# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/tables_command'
require 'tmpdir'
require 'fileutils'

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

    it 'produces names matching conveyor-belt provider convention' do
      # The terraform-provider-conveyor-belt normalizes table names with:
      #   strings.ReplaceAll(table, "_", "-")
      # Belt must produce DynamoDB table names that use the same convention.
      result = command.send(:table_name, 'blog_post')
      suffix = result.split('}').last
      expect(suffix).to eq('-blog-posts')
    end
  end

  describe 'end-to-end table generation' do
    around do |example|
      Dir.mktmpdir do |dir|
        @project_dir = dir
        FileUtils.mkdir_p(File.join(dir, 'infrastructure/modules/app'))
        FileUtils.mkdir_p(File.join(dir, 'lambda/models'))
        Dir.chdir(dir) { example.run }
      end
    end

    it 'generates dynamodb.tf with hyphenated table names' do
      File.write(File.join(@project_dir, 'lambda/models/order_item.rb'), <<~RUBY)
        class OrderItem < ApplicationRecord
        end
      RUBY

      described_class.new(quiet: true).run

      tf_content = File.read(File.join(@project_dir, 'infrastructure/modules/app/dynamodb.tf'))
      # The DynamoDB table name attribute should use hyphens
      expect(tf_content).to include('name         = "${var.app_name}-${var.environment}-order-items"')
      # The Terraform resource label can still use underscores (that's the HCL identifier)
      expect(tf_content).to include('resource "aws_dynamodb_table" "order_items"')
    end
  end
end
