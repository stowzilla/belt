# frozen_string_literal: true

require 'spec_helper'
require 'belt/route_dsl'

RSpec.describe 'Route DSL: throttle inheritance (Fizzy #2010)' do
  before { Belt.instance_variable_set(:@application, nil) }

  def throttles(&)
    Belt.application.routes.draw(&).api_gateways.flat_map(&:routes)
        .to_h { |r| ["#{r.method} #{r.path}", r.throttle] }
  end

  it 'applies the gateway default, route overrides and throttle: false opt-outs' do
    t = throttles do
      gateway :api, auth: :none, throttle: { rate: 50, burst: 100 } do
        get '/health', to: 'health#show', throttle: false
        post '/reports', to: 'reports#create', throttle: { rate: 5, burst: 10 }
        resource :profile, only: [:show]
      end
    end

    expect(t['GET /health']).to be_nil
    expect(t['POST /reports']).to eq(rate: 5, burst: 10)
    expect(t['GET /profile']).to eq(rate: 50, burst: 100)
  end

  it 'passes a resources throttle down to nested, member and collection routes' do
    t = throttles do
      gateway :api, throttle: { rate: 50, burst: 100 } do
        resources :matches, only: %i[create], throttle: { rate: 2, burst: 4 } do
          resources :moves, only: [:create]
          member { post :forfeit }
          collection { get :recent, throttle: false }
        end
      end
    end

    expect(t['POST /matches']).to eq(rate: 2, burst: 4)
    expect(t['POST /matches/{match_id}/moves']).to eq(rate: 2, burst: 4)
    expect(t['POST /matches/{match_id}/forfeit']).to eq(rate: 2, burst: 4)
    expect(t['GET /matches/recent']).to be_nil
  end

  it 'inherits from scope, namespace and function blocks, nearest block winning' do
    t = throttles do
      gateway :api, throttle: { rate: 50, burst: 100 } do
        scope path: 'v1', throttle: { rate: 9, burst: 9 } do
          resources :games, only: [:create] do
            resources :turns, only: [:create]
            scope path: 'billing', throttle: { rate: 1, burst: 1 } do
              post :checkout
            end
          end
        end
        namespace :admin, throttle: false do
          resources :users, only: [:index]
        end
        function :jobs, throttle: { rate: 3, burst: 3 } do
          post '/jobs', to: 'jobs#create'
        end
        get '/open', to: 'open#show'
      end
    end

    expect(t['POST /v1/games']).to eq(rate: 9, burst: 9)
    expect(t['POST /v1/games/{game_id}/turns']).to eq(rate: 9, burst: 9)
    expect(t['POST /v1/games/{game_id}/billing/checkout']).to eq(rate: 1, burst: 1)
    expect(t['GET /admin/users']).to be_nil
    expect(t['POST /jobs']).to eq(rate: 3, burst: 3)
    expect(t['GET /open']).to eq(rate: 50, burst: 100)
  end

  it 'gives the injected GET / welcome route the gateway default' do
    require 'belt/cli/routes_command'
    dsl = Belt.application.routes.draw do
      gateway(:api, throttle: { rate: 50, burst: 100 }) { get '/health', to: 'health#show' }
    end
    command = Belt::CLI::RoutesCommand.new([])
    command.instance_variable_set(:@table_inference, Belt::TableInference.new(nil))
    root = command.send(:collect_routes, dsl).find { |r| r[:path] == '/' }

    expect(root[:throttle]).to eq(rate: 50, burst: 100)
  end

  it 'rejects a bad value where it is declared' do
    expect { throttles { gateway(:api, throttle: { rate: 0, burst: 1 }) } }
      .to raise_error(ArgumentError, /rate must be a number > 0/)
    expect { throttles { gateway(:api) { scope(throttle: 5) { get '/x' } } } }
      .to raise_error(ArgumentError, /must be a Hash/)
  end
end
