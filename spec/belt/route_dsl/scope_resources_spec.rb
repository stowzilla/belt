# frozen_string_literal: true

require 'spec_helper'
require 'belt/route_dsl'

RSpec.describe 'RouteBuilder#resources inside scope' do
  def build_routes(&block)
    Belt.instance_variable_set(:@application, nil)
    routes = Belt.application.routes.draw do
      gateway :api do
        instance_eval(&block)
      end
    end
    routes.api_gateways.first.routes
  end

  describe 'resources without scope' do
    it 'generates standard paths' do
      routes = build_routes do
        resources :users
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/users'])
      expect(paths).to include(['POST', '/users'])
      expect(paths).to include(['GET', '/users/{user_id}'])
      expect(paths).to include(['PUT', '/users/{user_id}'])
      expect(paths).to include(['DELETE', '/users/{user_id}'])
    end
  end

  describe 'resources inside scope path' do
    it 'prefixes paths with scope' do
      routes = build_routes do
        scope path: 'admin' do
          resources :users
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/admin/users'])
      expect(paths).to include(['POST', '/admin/users'])
      expect(paths).to include(['GET', '/admin/users/{user_id}'])
      expect(paths).to include(['PUT', '/admin/users/{user_id}'])
      expect(paths).to include(['DELETE', '/admin/users/{user_id}'])
    end

    it 'sets controller to scope/resource_name' do
      routes = build_routes do
        scope path: 'admin' do
          resources :users
        end
      end

      controllers = routes.map(&:controller).uniq
      expect(controllers).to eq(['admin/users'])
    end

    it 'inherits auth from scope' do
      routes = build_routes do
        scope path: 'admin', auth: :cognito do
          resources :users
        end
      end

      auths = routes.map(&:auth).uniq
      expect(auths).to eq([:cognito])
    end

    it 'inherits tables from scope' do
      routes = build_routes do
        scope path: 'admin', tables: [:audit_log] do
          resources :users, tables: [:users]
        end
      end

      routes.each do |route|
        expect(route.tables).to include(:audit_log)
        expect(route.tables).to include(:users)
      end
    end

    it 'respects :only option' do
      routes = build_routes do
        scope path: 'admin' do
          resources :users, only: %i[index show]
        end
      end

      methods = routes.map(&:method)
      expect(methods).to contain_exactly('GET', 'GET')
      expect(routes.map(&:path)).to contain_exactly('/admin/users', '/admin/users/{user_id}')
    end

    it 'respects :except option' do
      routes = build_routes do
        scope path: 'admin' do
          resources :users, except: [:destroy]
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).not_to include(['DELETE', '/admin/users/{user_id}'])
      expect(paths).to include(['GET', '/admin/users'])
      expect(paths).to include(['PUT', '/admin/users/{user_id}'])
    end

    it 'supports multiple resources in same scope' do
      routes = build_routes do
        scope path: 'admin', auth: :cognito do
          resources :users, tables: [:users]
          resources :sponsors, tables: [:sponsors]
        end
      end

      user_paths = routes.select { |r| r.path.include?('users') }.map(&:path)
      sponsor_paths = routes.select { |r| r.path.include?('sponsors') }.map(&:path)

      expect(user_paths).to include('/admin/users', '/admin/users/{user_id}')
      expect(sponsor_paths).to include('/admin/sponsors', '/admin/sponsors/{sponsor_id}')
    end

    it 'supports nested block routes' do
      routes = build_routes do
        scope path: 'admin' do
          resources :slots, only: %i[index show update] do
            post '/import', on: :collection
          end
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/admin/slots'])
      expect(paths).to include(['GET', '/admin/slots/{slot_id}'])
      expect(paths).to include(['PUT', '/admin/slots/{slot_id}'])
      expect(paths).to include(['POST', '/admin/slots/import'])

      import_route = routes.find { |r| r.path == '/admin/slots/import' }
      expect(import_route.controller).to eq('admin/slots')
    end
  end

  describe 'resource (singular) inside scope' do
    it 'prefixes paths with scope' do
      routes = build_routes do
        scope path: 'admin' do
          resource :profile
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/admin/profile'])
      expect(paths).to include(['PUT', '/admin/profile'])
      expect(paths).to include(['DELETE', '/admin/profile'])
    end
  end
end
