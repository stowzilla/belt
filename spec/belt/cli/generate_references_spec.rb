# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'belt/cli/generate_command'

RSpec.describe 'Generate command — references support' do
  let(:tmpdir) { Dir.mktmpdir }

  before do
    @original_dir = Dir.pwd
    Dir.chdir(tmpdir)

    # Minimal Belt app structure
    FileUtils.mkdir_p('config')
    FileUtils.mkdir_p('lambda/models')
    FileUtils.mkdir_p('lambda/controllers/blog')
    FileUtils.mkdir_p('lambda/lib/routes')
    FileUtils.mkdir_p('infrastructure/modules/app')

    File.write('config/routes.rb', <<~RUBY)
      Belt.application.routes.draw do
        namespace :blog do
          resources :posts, tables: [:posts]
        end
      end
    RUBY

    File.write('config/contracts.rb', <<~RUBY)
      Belt.application.schema.define do
        model :post do
          string :title
          text :body
          string :created_at
          string :updated_at
        end
      end
    RUBY

    File.write('lambda/lib/routes/blog_routes.rb', <<~RUBY)
      # frozen_string_literal: true

      module Routes
        BLOG = [
          { verb: 'GET', path: '/posts', controller: 'posts', action: 'index' },
          { verb: 'POST', path: '/posts', controller: 'posts', action: 'create' },
          { verb: 'GET', path: '/posts/{post_id}', controller: 'posts', action: 'show' },
          { verb: 'PUT', path: '/posts/{post_id}', controller: 'posts', action: 'update' },
          { verb: 'DELETE', path: '/posts/{post_id}', controller: 'posts', action: 'destroy' }
        ].freeze
      end
    RUBY

    File.write('lambda/models/post.rb', <<~RUBY)
      # frozen_string_literal: true

      class Post < ApplicationRecord
        attr_accessor :title
        attr_accessor :body
      end
    RUBY

    # Stub sync_tables — we don't want to actually run terraform
    allow(Belt::CLI::TablesCommand).to receive(:sync_all_environments)
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(tmpdir)
  end

  describe '.parse_field' do
    it 'parses a references field' do
      result = Belt::CLI::GenerateCommand.parse_field('post:references')
      expect(result).to eq({ name: 'post', type: 'references', referenced_model: 'post' })
    end

    it 'parses belongs_to as an alias for references' do
      result = Belt::CLI::GenerateCommand.parse_field('post:belongs_to')
      expect(result).to eq({ name: 'post', type: 'references', referenced_model: 'post' })
    end

    it 'parses a regular string field' do
      result = Belt::CLI::GenerateCommand.parse_field('title:string')
      expect(result).to eq({ name: 'title', type: 'string' })
    end

    it 'defaults to string when no type given' do
      result = Belt::CLI::GenerateCommand.parse_field('title')
      expect(result).to eq({ name: 'title', type: 'string' })
    end

    it 'parses other types unchanged' do
      result = Belt::CLI::GenerateCommand.parse_field('count:integer')
      expect(result).to eq({ name: 'count', type: 'integer' })
    end
  end

  describe 'field partitioning' do
    it 'separates references from regular fields' do
      cmd = Belt::CLI::GenerateCommand.new(
        'scaffold', 'comment',
        [
          { name: 'post', type: 'references', referenced_model: 'post' },
          { name: 'body', type: 'text' },
          { name: 'author', type: 'references', referenced_model: 'author' }
        ]
      )
      expect(cmd.instance_variable_get(:@references).length).to eq(2)
      expect(cmd.instance_variable_get(:@regular_fields).length).to eq(1)
    end
  end

  describe 'model generation with references' do
    before do
      Belt::CLI::GenerateCommand.new(
        'model', 'comment',
        [
          { name: 'post', type: 'references', referenced_model: 'post' },
          { name: 'body', type: 'text' }
        ]
      ).generate
    end

    it 'generates belongs_to declaration' do
      content = File.read('lambda/models/comment.rb')
      expect(content).to include('belongs_to :post')
    end

    it 'generates attr_accessor for the foreign key' do
      content = File.read('lambda/models/comment.rb')
      expect(content).to include('attr_accessor :post_id')
    end

    it 'generates attr_accessor for regular fields' do
      content = File.read('lambda/models/comment.rb')
      expect(content).to include('attr_accessor :body')
    end

    it 'does not generate belongs_to for regular fields' do
      content = File.read('lambda/models/comment.rb')
      expect(content).not_to include('belongs_to :body')
    end
  end

  describe 'model generation without references' do
    before do
      Belt::CLI::GenerateCommand.new(
        'model', 'tag',
        [{ name: 'label', type: 'string' }]
      ).generate
    end

    it 'generates a model without belongs_to' do
      content = File.read('lambda/models/tag.rb')
      expect(content).not_to include('belongs_to')
      expect(content).to include('attr_accessor :label')
    end
  end

  describe 'model generation with multiple references' do
    before do
      File.write('lambda/models/author.rb', <<~RUBY)
        # frozen_string_literal: true

        class Author < ApplicationRecord
          attr_accessor :name
        end
      RUBY

      Belt::CLI::GenerateCommand.new(
        'model', 'authoring',
        [
          { name: 'book', type: 'references', referenced_model: 'book' },
          { name: 'author', type: 'references', referenced_model: 'author' }
        ]
      ).generate
    end

    it 'generates both belongs_to declarations' do
      content = File.read('lambda/models/authoring.rb')
      expect(content).to include('belongs_to :book')
      expect(content).to include('belongs_to :author')
    end

    it 'generates both foreign key attrs' do
      content = File.read('lambda/models/authoring.rb')
      expect(content).to include('attr_accessor :book_id')
      expect(content).to include('attr_accessor :author_id')
    end
  end

  describe 'controller generation — nested (with references)' do
    before do
      Belt::CLI::GenerateCommand.new(
        'scaffold', 'comment',
        [
          { name: 'post', type: 'references', referenced_model: 'post' },
          { name: 'body', type: 'text' }
        ],
        force: true
      ).generate
    end

    it 'scopes index to the parent via foreign key' do
      content = File.read('lambda/controllers/blog/comments_controller.rb')
      expect(content).to include('Comment.where(post_id: params[:post_id]')
    end

    it 'uses the parent GSI for index queries' do
      content = File.read('lambda/controllers/blog/comments_controller.rb')
      expect(content).to include("index: 'PostIndex'")
    end

    it 'passes parent_id into create' do
      content = File.read('lambda/controllers/blog/comments_controller.rb')
      expect(content).to include('post_id: params[:post_id]')
    end

    it 'generates the standard REST actions' do
      content = File.read('lambda/controllers/blog/comments_controller.rb')
      expect(content).to include('def index')
      expect(content).to include('def create')
      expect(content).to include('def show')
      expect(content).to include('def update')
      expect(content).to include('def destroy')
    end
  end

  describe 'controller generation — flat (no references)' do
    before do
      Belt::CLI::GenerateCommand.new(
        'scaffold', 'tag',
        [{ name: 'label', type: 'string' }],
        force: true
      ).generate
    end

    it 'uses Model.all for the index action' do
      content = File.read('lambda/controllers/blog/tags_controller.rb')
      expect(content).to include('Tag.all')
    end

    it 'does not scope to any parent' do
      content = File.read('lambda/controllers/blog/tags_controller.rb')
      expect(content).not_to include('params[:post_id]')
      expect(content).not_to include('PostIndex')
    end
  end

  describe 'route injection — nested under existing parent' do
    before do
      Belt::CLI::GenerateCommand.new(
        'scaffold', 'comment',
        [
          { name: 'post', type: 'references', referenced_model: 'post' },
          { name: 'body', type: 'text' }
        ],
        force: true
      ).generate
    end

    it 'converts parent resources to block form with child nested inside' do
      content = File.read('config/routes.rb')
      expect(content).to include('resources :posts')
      expect(content).to include('resources :comments')
    end

    it 'nests the child resources under the parent' do
      content = File.read('config/routes.rb')
      # The child should appear between the parent's do..end
      expect(content).to match(/resources :posts.*do\n.*resources :comments/m)
    end
  end

  describe 'route injection — top-level (no references)' do
    before do
      Belt::CLI::GenerateCommand.new(
        'scaffold', 'tag',
        [{ name: 'label', type: 'string' }],
        force: true
      ).generate
    end

    it 'adds the resource at the namespace level' do
      content = File.read('config/routes.rb')
      expect(content).to include('resources :tags')
    end

    it 'does not nest under any parent' do
      content = File.read('config/routes.rb')
      expect(content).not_to match(/resources :tags.*do/m)
    end
  end

  describe 'route injection — parent already has a do block' do
    before do
      # Set up parent with existing block
      File.write('config/routes.rb', <<~RUBY)
        Belt.application.routes.draw do
          namespace :blog do
            resources :posts, tables: [:posts] do
              resources :likes, tables: [:likes]
            end
          end
        end
      RUBY

      Belt::CLI::GenerateCommand.new(
        'scaffold', 'comment',
        [
          { name: 'post', type: 'references', referenced_model: 'post' },
          { name: 'body', type: 'text' }
        ],
        force: true
      ).generate
    end

    it 'inserts into the existing parent block without duplicating' do
      content = File.read('config/routes.rb')
      expect(content).to include('resources :comments')
      expect(content).to include('resources :likes')
      # Only one "do" for posts
      expect(content.scan(/resources :posts.*do/).count).to eq(1)
    end
  end

  describe 'route manifest — nested paths' do
    before do
      Belt::CLI::GenerateCommand.new(
        'scaffold', 'comment',
        [
          { name: 'post', type: 'references', referenced_model: 'post' },
          { name: 'body', type: 'text' }
        ],
        force: true
      ).generate
    end

    it 'generates paths prefixed with the parent resource' do
      content = File.read('lambda/lib/routes/blog_routes.rb')
      expect(content).to include('/posts/{post_id}/comments')
    end

    it 'generates individual item paths with parent prefix' do
      content = File.read('lambda/lib/routes/blog_routes.rb')
      expect(content).to include('/posts/{post_id}/comments/{comment_id}')
    end

    it 'preserves existing routes for other resources' do
      content = File.read('lambda/lib/routes/blog_routes.rb')
      # Original post routes should still exist
      expect(content).to include("path: '/posts'")
    end
  end

  describe 'route manifest — flat paths' do
    before do
      Belt::CLI::GenerateCommand.new(
        'scaffold', 'tag',
        [{ name: 'label', type: 'string' }],
        force: true
      ).generate
    end

    it 'generates paths without any parent prefix' do
      content = File.read('lambda/lib/routes/blog_routes.rb')
      expect(content).to include("path: '/tags'")
      expect(content).to include("path: '/tags/{tag_id}'")
    end
  end

  describe 'parent model injection' do
    context 'when parent model file exists' do
      before do
        Belt::CLI::GenerateCommand.new(
          'scaffold', 'comment',
          [
            { name: 'post', type: 'references', referenced_model: 'post' },
            { name: 'body', type: 'text' }
          ],
          force: true
        ).generate
      end

      it 'injects has_many into the parent model' do
        content = File.read('lambda/models/post.rb')
        expect(content).to include('has_many :comments')
      end
    end

    context 'when parent model file does not exist' do
      before do
        FileUtils.rm_f('lambda/models/post.rb')
      end

      it 'skips gracefully without error' do
        expect do
          Belt::CLI::GenerateCommand.new(
            'scaffold', 'comment',
            [
              { name: 'post', type: 'references', referenced_model: 'post' },
              { name: 'body', type: 'text' }
            ],
            force: true
          ).generate
        end.not_to raise_error
      end
    end

    context 'when has_many already exists in parent' do
      before do
        File.write('lambda/models/post.rb', <<~RUBY)
          # frozen_string_literal: true

          class Post < ApplicationRecord
            has_many :comments, foreign_key: 'post_id', index: 'PostIndex'

            attr_accessor :title
            attr_accessor :body
          end
        RUBY

        Belt::CLI::GenerateCommand.new(
          'scaffold', 'comment',
          [
            { name: 'post', type: 'references', referenced_model: 'post' },
            { name: 'body', type: 'text' }
          ],
          force: true
        ).generate
      end

      it 'does not duplicate has_many' do
        content = File.read('lambda/models/post.rb')
        expect(content.scan('has_many :comments').count).to eq(1)
      end
    end
  end

  describe 'schema injection with references' do
    before do
      Belt::CLI::GenerateCommand.new(
        'scaffold', 'comment',
        [
          { name: 'post', type: 'references', referenced_model: 'post' },
          { name: 'body', type: 'text' }
        ],
        force: true
      ).generate
    end

    it 'adds foreign key as string type in schema' do
      content = File.read('config/contracts.rb')
      expect(content).to include('string :post_id')
    end

    it 'adds regular fields with appropriate types' do
      content = File.read('config/contracts.rb')
      expect(content).to include('text :body')
    end

    it 'adds timestamp fields' do
      content = File.read('config/contracts.rb')
      expect(content).to include('string :created_at')
      expect(content).to include('string :updated_at')
    end
  end
end
