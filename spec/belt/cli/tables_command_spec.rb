# frozen_string_literal: true

require 'spec_helper'
require 'belt/cli/tables_command'
require 'tmpdir'
require 'fileutils'

RSpec.describe Belt::CLI::TablesCommand do
  describe 'table name generation' do
    subject(:command) { described_class.new(quiet: true) }

    describe '#table_name (private)' do
      it 'replaces underscores with hyphens in the table name suffix' do
        result = command.send(:table_name, 'order_item')
        expect(result).to eq('${var.app_name}-${var.environment}-order-items')
      end

      it 'handles single-word model names' do
        result = command.send(:table_name, 'post')
        expect(result).to eq('${var.app_name}-${var.environment}-posts')
      end

      it 'handles model names with multiple underscores' do
        result = command.send(:table_name, 'user_profile_setting')
        expect(result).to eq('${var.app_name}-${var.environment}-user-profile-settings')
      end

      it 'produces names matching conveyor-belt provider convention' do
        # The terraform-provider-conveyor-belt normalizes table names with:
        #   strings.ReplaceAll(table, "_", "-")
        # Belt must produce DynamoDB table names that use the same convention.
        result = command.send(:table_name, 'blog_post')
        # The suffix after the last Terraform variable interpolation should use hyphens
        suffix = result.split('}').last
        expect(suffix).to eq('-blog-posts')
      end
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
