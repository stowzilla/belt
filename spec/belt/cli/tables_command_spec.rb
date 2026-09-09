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

    # cognito_authenticatable installs the GSI without an indexes() call. If the
    # generator didn't know that, the table would ship without EmailIndex and the
    # failure would surface as a broken email lookup in production.
    it 'generates EmailIndex for a cognito_authenticatable model' do
      File.write(File.join(@project_dir, 'lambda/models/user.rb'), <<~RUBY)
        class User < ApplicationRecord
          cognito_authenticatable
        end
      RUBY

      described_class.new(quiet: true).run

      tf_content = File.read(File.join(@project_dir, 'infrastructure/modules/app/dynamodb.tf'))
      expect(tf_content).to include('name            = "EmailIndex"')
      expect(tf_content).to include('hash_key        = "email"')
    end

    it 'honours a custom email index name' do
      File.write(File.join(@project_dir, 'lambda/models/user.rb'), <<~RUBY)
        class User < ApplicationRecord
          cognito_authenticatable email_index: 'PeopleEmailIndex'
        end
      RUBY

      described_class.new(quiet: true).run

      tf_content = File.read(File.join(@project_dir, 'infrastructure/modules/app/dynamodb.tf'))
      expect(tf_content).to include('name            = "PeopleEmailIndex"')
    end

    it 'omits the GSI when the model opts out' do
      File.write(File.join(@project_dir, 'lambda/models/user.rb'), <<~RUBY)
        class User < ApplicationRecord
          cognito_authenticatable email_index: false
        end
      RUBY

      described_class.new(quiet: true).run

      tf_content = File.read(File.join(@project_dir, 'infrastructure/modules/app/dynamodb.tf'))
      expect(tf_content).not_to include('EmailIndex')
    end

    it 'does not add the GSI for a commented-out declaration' do
      File.write(File.join(@project_dir, 'lambda/models/user.rb'), <<~RUBY)
        class User < ApplicationRecord
          # cognito_authenticatable
        end
      RUBY

      described_class.new(quiet: true).run

      tf_content = File.read(File.join(@project_dir, 'infrastructure/modules/app/dynamodb.tf'))
      expect(tf_content).not_to include('EmailIndex')
    end

    it 'generates a convention GSI for belongs_to' do
      File.write(File.join(@project_dir, 'lambda/models/comment.rb'), <<~RUBY)
        class Comment < ApplicationRecord
          belongs_to :post
        end
      RUBY

      described_class.new(quiet: true).run

      tf_content = File.read(File.join(@project_dir, 'infrastructure/modules/app/dynamodb.tf'))
      expect(tf_content).to include('name            = "PostIndex"')
      expect(tf_content).to include('hash_key        = "postId"')
    end

    # `index: false` means the model covers the reverse lookup some other way, usually
    # under a different key name. Generating the convention GSI anyway produces one on
    # an attribute that doesn't exist.
    it 'respects belongs_to index: false' do
      File.write(File.join(@project_dir, 'lambda/models/comment.rb'), <<~RUBY)
        class Comment < ApplicationRecord
          belongs_to :post, index: false
          belongs_to :author, foreign_key: 'author_sub', optional: true, index: false
          indexes('PostIndex' => { partition_key: 'post_id' })
        end
      RUBY

      described_class.new(quiet: true).run

      tf_content = File.read(File.join(@project_dir, 'infrastructure/modules/app/dynamodb.tf'))
      expect(tf_content).not_to include('AuthorIndex')
      expect(tf_content).not_to include('"postId"')
      expect(tf_content).to include('hash_key        = "post_id"')
    end
  end
end
