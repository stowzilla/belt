# frozen_string_literal: true

require 'spec_helper'
require 'belt/route_dsl'

RSpec.describe 'gateway, function, namespace, scope interactions' do
  def build_routes(&block)
    Belt.instance_variable_set(:@application, nil)
    routes = Belt.application.routes.draw do
      gateway :api do
        instance_eval(&block)
      end
    end
    routes.api_gateways.first.routes
  end

  describe 'function nested inside namespace' do
    it 'inherits path prefix from namespace but uses function lambda' do
      routes = build_routes do
        namespace :admin do
          send(:function, :admin_worker) do
            resources :tasks, only: [:index]
          end
        end
      end

      route = routes.find { |r| r.path == '/admin/tasks' }
      expect(route).not_to be_nil
      expect(route.lambda).to eq('admin_worker')
      expect(route.controller).to eq('admin/tasks')
    end

    it 'generates all CRUD routes with correct attributes' do
      routes = build_routes do
        namespace :admin do
          send(:function, :admin_worker) do
            resources :tasks
          end
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/admin/tasks'])
      expect(paths).to include(['POST', '/admin/tasks'])
      expect(paths).to include(['GET', '/admin/tasks/{task_id}'])
      expect(paths).to include(['PUT', '/admin/tasks/{task_id}'])
      expect(paths).to include(['DELETE', '/admin/tasks/{task_id}'])

      routes.each do |route|
        expect(route.lambda).to eq('admin_worker')
        expect(route.controller).to eq('admin/tasks')
      end
    end
  end

  describe 'namespace inside function' do
    it 'inherits lambda from function while getting path prefix from namespace' do
      routes = build_routes do
        send(:function, :worker) do
          namespace :admin do
            resources :jobs, only: [:index]
          end
        end
      end

      route = routes.find { |r| r.path == '/admin/jobs' }
      expect(route).not_to be_nil
      expect(route.lambda).to eq('worker')
      expect(route.controller).to eq('admin/jobs')
    end

    it 'generates all CRUD routes with correct attributes' do
      routes = build_routes do
        send(:function, :worker) do
          namespace :admin do
            resources :jobs
          end
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/admin/jobs'])
      expect(paths).to include(['POST', '/admin/jobs'])
      expect(paths).to include(['GET', '/admin/jobs/{job_id}'])
      expect(paths).to include(['PUT', '/admin/jobs/{job_id}'])
      expect(paths).to include(['DELETE', '/admin/jobs/{job_id}'])

      routes.each do |route|
        expect(route.lambda).to eq('worker')
        expect(route.controller).to eq('admin/jobs')
      end
    end
  end

  describe 'nested scope modules' do
    it 'nests module prefixes in controller path' do
      routes = build_routes do
        scope module: 'a' do
          scope module: 'b' do
            resources :things, only: [:index]
          end
        end
      end

      route = routes.find { |r| r.path == '/things' }
      expect(route).not_to be_nil
      expect(route.controller).to eq('a/b/things')
      expect(route.lambda).to eq(:api)
    end

    it 'correctly generates all CRUD routes' do
      routes = build_routes do
        scope module: 'v1' do
          scope module: 'internal' do
            resources :widgets
          end
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/widgets'])
      expect(paths).to include(['POST', '/widgets'])
      expect(paths).to include(['GET', '/widgets/{widget_id}'])
      expect(paths).to include(['PUT', '/widgets/{widget_id}'])
      expect(paths).to include(['DELETE', '/widgets/{widget_id}'])

      routes.each do |route|
        expect(route.controller).to eq('v1/internal/widgets')
      end
    end
  end

  describe 'singular resource inside namespace' do
    it 'prefixes path and sets controller correctly' do
      routes = build_routes do
        namespace :admin do
          resource :dashboard
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/admin/dashboard'])
      expect(paths).to include(['PUT', '/admin/dashboard'])
      expect(paths).to include(['DELETE', '/admin/dashboard'])

      routes.each do |route|
        expect(route.controller).to eq('admin/dashboard')
        expect(route.lambda).to eq(:api)
      end
    end

    it 'respects :only option' do
      routes = build_routes do
        namespace :settings do
          resource :profile, only: %i[show update]
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to contain_exactly(['GET', '/settings/profile'], ['PUT', '/settings/profile'])

      routes.each do |route|
        expect(route.controller).to eq('settings/profile')
      end
    end
  end

  describe 'function with nested resources block' do
    it 'correctly routes nested resources within function context' do
      routes = build_routes do
        send(:function, :billing) do
          resources :invoices do
            resources :line_items, only: %i[index create]
          end
        end
      end

      invoice_routes = routes.select { |r| r.path.start_with?('/invoices') && !r.path.include?('line_items') }
      line_item_routes = routes.select { |r| r.path.include?('line_items') }

      expect(invoice_routes.map(&:lambda).uniq).to eq(['billing'])
      expect(line_item_routes.map(&:lambda).uniq).to eq(['billing'])

      line_item_paths = line_item_routes.map { |r| [r.method, r.path] }
      expect(line_item_paths).to include(['GET', '/invoices/{invoice_id}/line_items'])
      expect(line_item_paths).to include(['POST', '/invoices/{invoice_id}/line_items'])
    end

    it 'handles deeply nested resources' do
      routes = build_routes do
        send(:function, :inventory) do
          resources :warehouses do
            resources :shelves do
              resources :items, only: [:index]
            end
          end
        end
      end

      item_route = routes.find { |r| r.path.include?('items') }
      expect(item_route).not_to be_nil
      expect(item_route.path).to eq('/warehouses/{warehouse_id}/shelves/{shelf_id}/items')
      expect(item_route.lambda).to eq('inventory')
    end
  end

  describe 'scope controller: option propagation' do
    it 'overrides controller for all routes in scope' do
      routes = build_routes do
        scope path: 'v1', controller: 'api/v1/legacy' do
          resources :widgets, only: %i[index show]
        end
      end

      routes.each do |route|
        expect(route.controller).to eq('api/v1/legacy')
      end

      paths = routes.map(&:path)
      expect(paths).to include('/v1/widgets')
      expect(paths).to include('/v1/widgets/{widget_id}')
    end

    it 'propagates to nested scopes unless overridden' do
      routes = build_routes do
        scope controller: 'base' do
          resources :posts, only: [:index]

          scope controller: 'override' do
            resources :comments, only: [:index]
          end
        end
      end

      post_route = routes.find { |r| r.path == '/posts' }
      comment_route = routes.find { |r| r.path == '/comments' }

      expect(post_route.controller).to eq('base')
      expect(comment_route.controller).to eq('override')
    end
  end

  describe 'combined integration scenarios' do
    it 'handles complex nesting of function, namespace, and scope' do
      routes = build_routes do
        send(:function, :main_api) do
          namespace :admin do
            scope path: 'v2', module: 'v2' do
              resources :users, only: [:index]
            end
          end
        end
      end

      route = routes.find { |r| r.path == '/admin/v2/users' }
      expect(route).not_to be_nil
      expect(route.lambda).to eq('main_api')
      expect(route.controller).to eq('admin/v2/users')
    end

    it 'allows function to override gateway default even deep in namespace nesting' do
      routes = build_routes do
        namespace :api do
          namespace :v1 do
            resources :posts, only: [:index]

            send(:function, :heavy_compute) do
              resources :reports, only: [:index]
            end
          end
        end
      end

      posts_route = routes.find { |r| r.path == '/api/v1/posts' }
      reports_route = routes.find { |r| r.path == '/api/v1/reports' }

      expect(posts_route.lambda).to eq(:api)
      expect(posts_route.controller).to eq('api/v1/posts')

      expect(reports_route.lambda).to eq('heavy_compute')
      expect(reports_route.controller).to eq('api/v1/reports')
    end
  end
end
