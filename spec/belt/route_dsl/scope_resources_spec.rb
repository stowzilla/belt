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
      expect(paths).to include(['GET', '/users/{id}'])
      expect(paths).to include(['PUT', '/users/{id}'])
      expect(paths).to include(['DELETE', '/users/{id}'])
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
      expect(paths).to include(['GET', '/admin/users/{id}'])
      expect(paths).to include(['PUT', '/admin/users/{id}'])
      expect(paths).to include(['DELETE', '/admin/users/{id}'])
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
      expect(routes.map(&:path)).to contain_exactly('/admin/users', '/admin/users/{id}')
    end

    it 'respects :except option' do
      routes = build_routes do
        scope path: 'admin' do
          resources :users, except: [:destroy]
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).not_to include(['DELETE', '/admin/users/{id}'])
      expect(paths).to include(['GET', '/admin/users'])
      expect(paths).to include(['PUT', '/admin/users/{id}'])
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

      expect(user_paths).to include('/admin/users', '/admin/users/{id}')
      expect(sponsor_paths).to include('/admin/sponsors', '/admin/sponsors/{id}')
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
      # When resources has a nested block, member routes use {param_name} to avoid
      # API Gateway sibling path parameter conflicts
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

  describe 'scope path with a param segment (fizzy-1383)' do
    it 'normalizes :param segments to API Gateway {param} form' do
      routes = build_routes do
        scope path: 'accounts/:account_id' do
          resources :changes
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/accounts/{account_id}/changes'])
      expect(paths).to include(['POST', '/accounts/{account_id}/changes'])
      expect(paths).to include(['GET', '/accounts/{account_id}/changes/{id}'])
      expect(paths).to include(['PUT', '/accounts/{account_id}/changes/{id}'])
      expect(paths).to include(['DELETE', '/accounts/{account_id}/changes/{id}'])
    end

    it 'does not leak the raw :param or {param} segment into any path' do
      routes = build_routes do
        scope path: 'accounts/:account_id' do
          resources :changes
        end
      end

      expect(routes.map(&:path)).to all(satisfy { |p| !p.include?(':account_id') })
    end

    it 'excludes param segments from the derived controller module' do
      routes = build_routes do
        scope path: 'accounts/:account_id' do
          resources :changes
        end
      end

      # Static segment "accounts" stays as the module; "{account_id}" is stripped.
      expect(routes.map(&:controller).uniq).to eq(['accounts/changes'])
    end

    it 'derives a clean controller when the scope path is only a param' do
      routes = build_routes do
        scope path: ':account_id' do
          resources :changes
        end
      end

      expect(routes.map(&:path)).to all(eq('/{account_id}/changes').or(eq('/{account_id}/changes/{id}')))
      expect(routes.map(&:controller).uniq).to eq(['changes'])
    end

    it 'accepts a param already in {param} form' do
      routes = build_routes do
        scope path: 'accounts/{account_id}' do
          resources :changes
        end
      end

      expect(routes.map { |r| [r.method, r.path] }).to include(['GET', '/accounts/{account_id}/changes'])
      expect(routes.map(&:controller).uniq).to eq(['accounts/changes'])
    end

    it 'normalizes params for plain member/collection routes too' do
      routes = build_routes do
        scope path: 'accounts/:account_id' do
          get 'summary'
        end
      end

      expect(routes.map(&:path)).to eq(['/accounts/{account_id}/summary'])
    end
  end
end
