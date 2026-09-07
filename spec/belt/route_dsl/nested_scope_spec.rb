# frozen_string_literal: true

require 'spec_helper'
require 'belt/route_dsl'

RSpec.describe 'NestedResourceBuilder scope and action inference' do
  def build_routes(&block)
    Belt.instance_variable_set(:@application, nil)
    routes = Belt.application.routes.draw do
      gateway :api do
        instance_eval(&block)
      end
    end
    routes.api_gateways.first.routes
  end

  describe 'scope inside nested resources' do
    it 'allows scope inside resources block with path and controller' do
      routes = build_routes do
        resources :projects do
          scope path: 'billing', controller: :billing do
            get '/', action: :show
            post :checkout
            post :subscribe
            post :cancel
          end
        end
      end

      billing_routes = routes.select { |r| r.path.include?('billing') }
      expect(billing_routes.length).to eq(4)

      show_route = routes.find { |r| r.path == '/projects/{project_id}/billing' && r.method == 'GET' }
      expect(show_route).not_to be_nil
      expect(show_route.controller).to eq('billing')
      expect(show_route.action).to eq(:show)

      checkout_route = routes.find { |r| r.path == '/projects/{project_id}/billing/checkout' }
      expect(checkout_route).not_to be_nil
      expect(checkout_route.controller).to eq('billing')
      expect(checkout_route.action).to eq(:checkout)
    end

    it 'inherits tables from scope' do
      routes = build_routes do
        resources :projects do
          scope path: 'billing', tables: [:memberships] do
            get :show
            post :checkout
          end
        end
      end

      routes.select { |r| r.path.include?('billing') }.each do |route|
        expect(route.tables).to include(:memberships)
        expect(route.tables).to include(:projects) # inherited from parent resource
      end
    end

    it 'inherits auth from scope' do
      routes = build_routes do
        resources :projects do
          scope path: 'admin', auth: :admin do
            get :dashboard
          end
        end
      end

      dashboard_route = routes.find { |r| r.path.include?('dashboard') }
      expect(dashboard_route.auth).to eq(:admin)
    end

    it 'allows nested scopes' do
      routes = build_routes do
        resources :projects do
          scope path: 'settings' do
            scope path: 'notifications' do
              get :email
              get :sms
            end
          end
        end
      end

      email_route = routes.find { |r| r.path.include?('email') }
      expect(email_route.path).to eq('/projects/{project_id}/settings/notifications/email')

      sms_route = routes.find { |r| r.path.include?('sms') }
      expect(sms_route.path).to eq('/projects/{project_id}/settings/notifications/sms')
    end
  end

  describe 'singular resource inside nested resources' do
    it 'creates singular resource routes' do
      routes = build_routes do
        resources :projects do
          resource :billing, only: %i[show update]
        end
      end

      paths = routes.map { |r| [r.method, r.path] }
      expect(paths).to include(['GET', '/projects/{project_id}/billing'])
      expect(paths).to include(['PUT', '/projects/{project_id}/billing'])
      expect(paths).not_to include(['DELETE', '/projects/{project_id}/billing'])
    end

    it 'inherits tables from parent resource' do
      routes = build_routes do
        resources :projects, tables: [:projects] do
          resource :token_usage, only: [:show], tables: [:token_usages]
        end
      end

      token_route = routes.find { |r| r.path.include?('token_usage') }
      expect(token_route.tables).to include(:projects)
      expect(token_route.tables).to include(:token_usages)
    end

    it 'inherits auth from parent' do
      routes = build_routes do
        resources :projects do
          resource :profile, only: [:show]
        end
      end

      profile_route = routes.find { |r| r.path.include?('profile') }
      expect(profile_route.auth).to eq(:none) # gateway default
    end

    it 'supports :create action' do
      routes = build_routes do
        resources :projects do
          resource :ci_results, only: [:create]
        end
      end

      paths = routes.select { |r| r.path.include?('ci_results') }.map { |r| [r.method, r.path] }
      expect(paths).to eq([['POST', '/projects/{project_id}/ci_results']])
    end
  end

  describe 'action inference from path' do
    it 'infers action from symbol path in member block' do
      routes = build_routes do
        resources :webhooks do
          member do
            post :test
          end
        end
      end

      test_route = routes.find { |r| r.path == '/webhooks/{webhook_id}/test' }
      expect(test_route).not_to be_nil
      expect(test_route.action).to eq(:test)
      expect(test_route.controller).to eq('webhooks')
    end

    it 'infers action from symbol path in collection block' do
      routes = build_routes do
        resources :surfaces do
          collection do
            get :teams
          end
        end
      end

      teams_route = routes.find { |r| r.path == '/surfaces/teams' }
      expect(teams_route).not_to be_nil
      expect(teams_route.action).to eq(:teams)
      expect(teams_route.controller).to eq('surfaces')
    end

    it 'infers action from string path when not specified' do
      routes = build_routes do
        resources :conversations do
          member do
            post 'chat'
          end
        end
      end

      chat_route = routes.find { |r| r.path.include?('chat') }
      expect(chat_route.action).to eq(:chat)
    end

    it 'respects explicit action over inferred' do
      routes = build_routes do
        resources :posts do
          member do
            post :approve, action: :mark_as_approved
          end
        end
      end

      approve_route = routes.find { |r| r.path.include?('approve') }
      expect(approve_route.action).to eq(:mark_as_approved)
    end

    it 'infers action from nested resource direct routes' do
      routes = build_routes do
        resources :projects do
          post :archive
          get :stats
        end
      end

      archive_route = routes.find { |r| r.path.include?('archive') }
      expect(archive_route.action).to eq(:archive)

      stats_route = routes.find { |r| r.path.include?('stats') }
      expect(stats_route.action).to eq(:stats)
    end

    it 'converts hyphens to underscores in action names' do
      routes = build_routes do
        resources :projects do
          member do
            post 'mark-complete'
          end
        end
      end

      route = routes.find { |r| r.path.include?('mark-complete') }
      expect(route.action).to eq(:mark_complete)
    end
  end

  describe 'controller inheritance in member/collection' do
    it 'inherits controller from parent resource in member block' do
      routes = build_routes do
        resources :surfaces do
          member do
            put :assign
          end
        end
      end

      assign_route = routes.find { |r| r.path.include?('assign') }
      expect(assign_route.controller).to eq('surfaces')
    end

    it 'inherits controller from parent resource in collection block' do
      routes = build_routes do
        resources :surfaces do
          collection do
            get :teams
          end
        end
      end

      teams_route = routes.find { |r| r.path == '/surfaces/teams' }
      expect(teams_route.controller).to eq('surfaces')
    end

    it 'allows controller override in member block' do
      routes = build_routes do
        resources :projects do
          member do
            get :billing, controller: :project_billing
          end
        end
      end

      billing_route = routes.find { |r| r.path.include?('billing') }
      expect(billing_route.controller.to_s).to eq('project_billing')
    end
  end

  describe 'ideal routes file example from ROUTING_IMPROVEMENTS.md' do
    it 'supports the ideal DRY syntax' do
      routes = build_routes do
        resources :projects, tables: [:surfaces] do
          resources :surfaces, tables: [:memberships] do
            collection do
              get :teams
            end
            member do
              put :assign
            end
          end

          resources :webhooks do
            member do
              post :test
            end
          end

          resources :conversations, only: %i[index create show destroy], tables: [:messages] do
            member do
              post :chat, tables: [:token_usages]
            end
          end

          resource :token_usage, only: [:show]

          scope path: 'billing', controller: :billing, tables: [:memberships] do
            get '/', action: :show
            post :checkout
            post :subscribe
            post :cancel
            post :portal
          end
        end
      end

      # Check surfaces routes
      teams_route = routes.find { |r| r.path == '/projects/{project_id}/surfaces/teams' }
      expect(teams_route).not_to be_nil
      expect(teams_route.action).to eq(:teams)
      expect(teams_route.controller).to eq('surfaces')

      assign_route = routes.find { |r| r.path == '/projects/{project_id}/surfaces/{surface_id}/assign' }
      expect(assign_route).not_to be_nil
      expect(assign_route.action).to eq(:assign)

      # Check webhooks
      test_route = routes.find { |r| r.path == '/projects/{project_id}/webhooks/{webhook_id}/test' }
      expect(test_route).not_to be_nil
      expect(test_route.action).to eq(:test)

      # Check conversations chat
      chat_route = routes.find { |r| r.path == '/projects/{project_id}/conversations/{conversation_id}/chat' }
      expect(chat_route).not_to be_nil
      expect(chat_route.tables).to include(:messages)
      expect(chat_route.tables).to include(:token_usages)

      # Check singular resource
      token_route = routes.find { |r| r.path == '/projects/{project_id}/token_usage' }
      expect(token_route).not_to be_nil
      expect(token_route.method).to eq('GET')

      # Check billing scope
      billing_show = routes.find { |r| r.path == '/projects/{project_id}/billing' && r.method == 'GET' }
      expect(billing_show).not_to be_nil
      expect(billing_show.controller).to eq('billing')
      expect(billing_show.action).to eq(:show)
      expect(billing_show.tables).to include(:memberships)

      billing_checkout = routes.find { |r| r.path == '/projects/{project_id}/billing/checkout' }
      expect(billing_checkout).not_to be_nil
      expect(billing_checkout.controller).to eq('billing')
      expect(billing_checkout.action).to eq(:checkout)
    end
  end
end
