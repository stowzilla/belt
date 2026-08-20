# frozen_string_literal: true

require 'spec_helper'
require 'belt/route_dsl'

RSpec.describe 'Route DSL: per-action request_model' do
  before { Belt.instance_variable_set(:@application, nil) }

  def build_routes(&block)
    dsl = Belt.application.routes.draw(&block)
    dsl.api_gateways
  end

  describe 'Hash-style request_model on resources' do
    it 'resolves different request_model per action' do
      gateways = build_routes do
        gateway :api do
          resources :items, only: %i[index show create update],
                            request_model: { create: :create_item, update: :update_item }
        end
      end

      routes = gateways.first.routes
      post_route = routes.find { |r| r.method == 'POST' }
      put_route = routes.find { |r| r.method == 'PUT' }
      get_routes = routes.select { |r| r.method == 'GET' }

      expect(post_route.request_model).to eq('create_item')
      expect(put_route.request_model).to eq('update_item')
      get_routes.each { |r| expect(r.request_model).to be_nil }
    end

    it 'allows specifying only create (no update)' do
      gateways = build_routes do
        gateway :api do
          resources :items, only: %i[create update],
                            request_model: { create: :create_item }
        end
      end

      routes = gateways.first.routes
      post_route = routes.find { |r| r.method == 'POST' }
      put_route = routes.find { |r| r.method == 'PUT' }

      expect(post_route.request_model).to eq('create_item')
      expect(put_route.request_model).to be_nil
    end

    it 'allows specifying only update (no create)' do
      gateways = build_routes do
        gateway :api do
          resources :items, only: %i[create update],
                            request_model: { update: :update_item }
        end
      end

      routes = gateways.first.routes
      post_route = routes.find { |r| r.method == 'POST' }
      put_route = routes.find { |r| r.method == 'PUT' }

      expect(post_route.request_model).to be_nil
      expect(put_route.request_model).to eq('update_item')
    end

    it 'accepts string keys as well as symbols' do
      gateways = build_routes do
        gateway :api do
          resources :items, only: %i[create update],
                            request_model: { 'create' => :create_item, 'update' => :update_item }
        end
      end

      routes = gateways.first.routes
      post_route = routes.find { |r| r.method == 'POST' }
      put_route = routes.find { |r| r.method == 'PUT' }

      expect(post_route.request_model).to eq('create_item')
      expect(put_route.request_model).to eq('update_item')
    end
  end

  describe 'Symbol-style request_model on resources (backwards compatibility)' do
    it 'applies the same request_model to all routes' do
      gateways = build_routes do
        gateway :api do
          resources :items, only: %i[create update],
                            request_model: :item_payload
        end
      end

      routes = gateways.first.routes
      post_route = routes.find { |r| r.method == 'POST' }
      put_route = routes.find { |r| r.method == 'PUT' }

      expect(post_route.request_model).to eq('item_payload')
      expect(put_route.request_model).to eq('item_payload')
    end
  end

  describe 'Hash-style request_model on singular resource' do
    it 'resolves per-action' do
      gateways = build_routes do
        gateway :api do
          resource :profile, only: %i[show create update],
                             request_model: { create: :create_profile, update: :update_profile }
        end
      end

      routes = gateways.first.routes
      post_route = routes.find { |r| r.method == 'POST' }
      put_route = routes.find { |r| r.method == 'PUT' }
      get_route = routes.find { |r| r.method == 'GET' }

      expect(post_route.request_model).to eq('create_profile')
      expect(put_route.request_model).to eq('update_profile')
      expect(get_route.request_model).to be_nil
    end
  end

  describe 'Hash-style request_model with scoped resources' do
    it 'resolves per-action in namespaced resources' do
      gateways = build_routes do
        gateway :api do
          namespace :admin do
            resources :users, only: %i[create update],
                              request_model: { create: :create_user, update: :update_user }
          end
        end
      end

      routes = gateways.first.routes
      post_route = routes.find { |r| r.method == 'POST' }
      put_route = routes.find { |r| r.method == 'PUT' }

      expect(post_route.request_model).to eq('create_user')
      expect(put_route.request_model).to eq('update_user')
    end
  end

  describe 'Hash-style request_model with nested resources' do
    it 'resolves per-action in nested resources' do
      gateways = build_routes do
        gateway :api do
          resources :posts, only: [:show] do
            resources :comments, only: %i[create update],
                                 request_model: { create: :create_comment, update: :update_comment }
          end
        end
      end

      routes = gateways.first.routes
      post_route = routes.find { |r| r.method == 'POST' }
      put_route = routes.find { |r| r.method == 'PUT' }

      expect(post_route.request_model).to eq('create_comment')
      expect(put_route.request_model).to eq('update_comment')
    end
  end
end
