# frozen_string_literal: true

require 'spec_helper'
require 'belt/route_dsl'

RSpec.describe 'Route DSL: gateway, lambda, namespace, and scope keywords' do
  before { Belt.instance_variable_set(:@application, nil) }

  def build_routes(&block)
    dsl = Belt.application.routes.draw(&block)
    dsl.api_gateways
  end

  describe 'gateway keyword' do
    it 'creates an API Gateway with the given name' do
      gateways = build_routes do
        gateway :api do
          resources :posts
        end
      end

      expect(gateways.length).to eq(1)
      expect(gateways.first.name).to eq('api')
    end

    it 'passes auth option to the gateway' do
      gateways = build_routes do
        gateway :api, auth: :cognito do
          resources :posts
        end
      end

      gateways.first.routes.each do |route|
        expect(route.auth).to eq(:cognito)
      end
    end

    it 'sets default lambda to gateway name' do
      gateways = build_routes do
        gateway :api do
          resources :posts
        end
      end

      gateways.first.routes.each do |route|
        expect(route.lambda).to eq(:api)
      end
    end

    it 'supports multiple gateways' do
      gateways = build_routes do
        gateway :api, auth: :cognito do
          resources :posts
        end
        gateway :ops, auth: :iam do
          resources :admin_tasks, only: [:index]
        end
      end

      expect(gateways.map(&:name)).to eq(%w[api ops])
    end
  end

  describe 'legacy namespace keyword (alias for gateway)' do
    it 'still works as an alias for gateway' do
      gateways = build_routes do
        namespace :api do
          resources :posts
        end
      end

      expect(gateways.length).to eq(1)
      expect(gateways.first.name).to eq('api')
      expect(gateways.first.routes.first.lambda).to eq(:api)
    end
  end

  describe 'lambda keyword (inside RouteBuilder)' do
    it 'targets routes to a different Lambda function' do
      gateways = build_routes do
        gateway :api, auth: :cognito do
          resources :posts

          lambda :onboarding do
            resources :steps, only: %i[index create]
          end
        end
      end

      routes = gateways.first.routes
      post_routes = routes.select { |r| r.path.include?('posts') }
      step_routes = routes.select { |r| r.path.include?('steps') }

      post_routes.each { |r| expect(r.lambda).to eq(:api) }
      step_routes.each { |r| expect(r.lambda.to_s).to eq('onboarding') }
    end

    it 'supports multiple lambda blocks in the same gateway' do
      gateways = build_routes do
        gateway :api do
          resources :posts

          lambda :custom do
            get '/blah', action: :blah, controller: :custom
          end
        end
      end

      routes = gateways.first.routes
      post_routes = routes.select { |r| r.path.include?('posts') }
      stuff_routes = routes.select { |r| r.path.include?('stuff') }
      blah_route = routes.find { |r| r.path == '/blah' }

      post_routes.each { |r| expect(r.lambda).to eq(:api) }
      stuff_routes.each { |r| expect(r.lambda.to_s).to eq('onboarding') }
      expect(blah_route.lambda.to_s).to eq('custom')
    end

    it 'does not leak lambda context outside the block' do
      gateways = build_routes do
        gateway :api do
          send(:lambda, :worker) do
            resources :jobs, only: [:create]
          end
          resources :users, only: [:index]
        end
      end

      routes = gateways.first.routes
      job_route = routes.find { |r| r.path.include?('jobs') }
      user_route = routes.find { |r| r.path.include?('users') }

      expect(job_route.lambda.to_s).to eq('worker')
      expect(user_route.lambda).to eq(:api)
    end

    it 'can carry auth option' do
      gateways = build_routes do
        gateway :api, auth: :cognito do
          lambda :public_api, auth: :none do
            get '/health', action: :health, controller: :status
          end
        end
      end

      route = gateways.first.routes.first
      expect(route.auth).to eq(:none)
    end

    it 'can carry tables option' do
      gateways = build_routes do
        gateway :api do
          lambda :reports, tables: [:analytics] do
            resources :reports, only: [:index], tables: [:reports]
          end
        end
      end

      route = gateways.first.routes.first
      expect(route.tables).to include(:analytics)
      expect(route.tables).to include(:reports)
    end
  end

  describe 'namespace keyword (Rails-like, inside RouteBuilder)' do
    it 'adds both path prefix and module prefix' do
      gateways = build_routes do
        gateway :api do
          namespace :admin do
            resources :users
          end
        end
      end

      routes = gateways.first.routes
      paths = routes.map(&:path)
      expect(paths).to include('/admin/users')
      expect(paths).to include('/admin/users/{user_id}')

      controllers = routes.map(&:controller).uniq
      expect(controllers).to eq(['admin/users'])
    end

    it 'nests namespace inside namespace' do
      gateways = build_routes do
        gateway :api do
          namespace :admin do
            namespace :v2 do
              resources :users, only: [:index]
            end
          end
        end
      end

      route = gateways.first.routes.first
      expect(route.path).to eq('/admin/v2/users')
      expect(route.controller).to eq('admin/v2/users')
    end

    it 'inherits auth from parent namespace' do
      gateways = build_routes do
        gateway :api do
          namespace :admin, auth: :iam do
            resources :users, only: [:index]
          end
        end
      end

      route = gateways.first.routes.first
      expect(route.auth).to eq(:iam)
    end

    it 'does not affect routes outside the namespace' do
      gateways = build_routes do
        gateway :api do
          namespace :admin do
            resources :users, only: [:index]
          end
          resources :posts, only: [:index]
        end
      end

      routes = gateways.first.routes
      admin_route = routes.find { |r| r.path.include?('admin') }
      post_route = routes.find { |r| r.path.include?('posts') }

      expect(admin_route.path).to eq('/admin/users')
      expect(admin_route.controller).to eq('admin/users')
      expect(post_route.path).to eq('/posts')
      expect(post_route.controller).to be_nil # standard inference
    end
  end

  describe 'scope keyword (Rails-like, inside RouteBuilder)' do
    it 'scope with path: only adds path prefix (no module)' do
      gateways = build_routes do
        gateway :api do
          scope path: 'v1' do
            resources :posts, only: [:index]
          end
        end
      end

      route = gateways.first.routes.first
      expect(route.path).to eq('/v1/posts')
      # controller is v1/posts because path prefix determines controller when no module override
      expect(route.controller).to eq('v1/posts')
    end

    it 'scope with module: only adds module prefix (no path change)' do
      gateways = build_routes do
        gateway :api do
          scope module: 'v2' do
            resources :posts, only: [:index]
          end
        end
      end

      route = gateways.first.routes.first
      expect(route.path).to eq('/posts')
      expect(route.controller).to eq('v2/posts')
    end

    it 'scope with both path: and module: adds both' do
      gateways = build_routes do
        gateway :api do
          scope path: 'internal', module: 'admin' do
            resources :settings, only: [:index]
          end
        end
      end

      route = gateways.first.routes.first
      expect(route.path).to eq('/internal/settings')
      expect(route.controller).to eq('admin/settings')
    end

    it 'scope module: sets the lambda target' do
      gateways = build_routes do
        gateway :api do
          scope module: 'workers' do
            resources :jobs, only: [:create]
          end
        end
      end

      route = gateways.first.routes.first
      expect(route.lambda.to_s).to eq('workers')
    end
  end

  describe 'combined usage: gateway + lambda + namespace + scope' do
    it 'supports the full proposed DSL' do
      gateways = build_routes do
        gateway :api, auth: :cognito do
          resources :conversations do
            resources :messages, only: %i[index create]
          end

          send(:lambda, :onboarding) do
            resources :stuff
          end

          send(:lambda, :custom) do
            get '/blah', action: :blah, controller: :custom
          end

          namespace :admin do
            resources :users, only: %i[index show]
          end

          scope path: 'v2', module: 'v2' do
            resources :posts, only: [:index]
          end
        end
      end

      routes = gateways.first.routes

      # Conversations use default lambda (:api)
      convo_routes = routes.select { |r| r.path.start_with?('/conversations') && !r.path.include?('messages') }
      convo_routes.each { |r| expect(r.lambda).to eq(:api) }

      # Messages are nested under conversations
      msg_routes = routes.select { |r| r.path.include?('messages') }
      expect(msg_routes.map(&:path)).to include('/conversations/{conversation_id}/messages')

      # Onboarding lambda
      stuff_routes = routes.select { |r| r.path.include?('stuff') }
      stuff_routes.each { |r| expect(r.lambda.to_s).to eq('onboarding') }

      # Custom lambda
      blah_route = routes.find { |r| r.path == '/blah' }
      expect(blah_route.lambda.to_s).to eq('custom')

      # Namespace: admin
      admin_routes = routes.select { |r| r.path.start_with?('/admin') }
      admin_routes.each do |r|
        expect(r.controller).to start_with('admin/')
        expect(r.auth).to eq(:cognito) # inherited from gateway
      end

      # Scope: v2
      v2_route = routes.find { |r| r.path == '/v2/posts' }
      expect(v2_route.controller).to eq('v2/posts')
      expect(v2_route.lambda.to_s).to eq('v2')
    end
  end
end
