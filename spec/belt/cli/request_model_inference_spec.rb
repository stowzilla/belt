# frozen_string_literal: true

require 'spec_helper'
require 'belt/route_dsl'
require 'belt/cli/routes_command/request_model_inference'

RSpec.describe Belt::CLI::RoutesCommand::RequestModelInference do
  let(:test_class) do
    Class.new do
      include Belt::CLI::RoutesCommand::RequestModelInference

      # Expose private methods for testing
      public :infer_request_models!, :infer_request_model_for_route, :infer_response_model_for_route,
             :extract_singular_resource, :infer_verb_prefix, :load_contract_names
    end.new
  end

  before { Belt.instance_variable_set(:@application, nil) }

  describe '#infer_request_model_for_route' do
    let(:contract_names) { Set.new(%w[create_item update_item create_customer_item update_ops_item]) }

    it 'infers create model for POST on a resource' do
      route = { verb: 'POST', path: '/items', action: 'create', gateway: 'api' }
      result = test_class.infer_request_model_for_route(route, contract_names)
      expect(result).to eq('create_item')
    end

    it 'infers update model for PUT on a resource' do
      route = { verb: 'PUT', path: '/items/{item_id}', action: 'update', gateway: 'api' }
      result = test_class.infer_request_model_for_route(route, contract_names)
      expect(result).to eq('update_item')
    end

    it 'prefers gateway-scoped model over generic' do
      route = { verb: 'POST', path: '/items', action: 'create', gateway: 'customer' }
      result = test_class.infer_request_model_for_route(route, contract_names)
      expect(result).to eq('create_customer_item')
    end

    it 'falls back to generic when gateway-scoped not found' do
      route = { verb: 'PUT', path: '/items/{item_id}', action: 'update', gateway: 'customer' }
      result = test_class.infer_request_model_for_route(route, contract_names)
      expect(result).to eq('update_item')
    end

    it 'uses gateway-scoped model for update when available' do
      route = { verb: 'PUT', path: '/items/{item_id}', action: 'update', gateway: 'ops' }
      result = test_class.infer_request_model_for_route(route, contract_names)
      expect(result).to eq('update_ops_item')
    end

    it 'returns nil when no matching contract exists' do
      route = { verb: 'POST', path: '/widgets', action: 'create', gateway: 'api' }
      result = test_class.infer_request_model_for_route(route, contract_names)
      expect(result).to be_nil
    end

    it 'returns nil for GET requests' do
      route = { verb: 'GET', path: '/items', action: 'index', gateway: 'api' }
      result = test_class.infer_request_model_for_route(route, contract_names)
      expect(result).to be_nil
    end

    it 'returns nil for DELETE requests' do
      route = { verb: 'DELETE', path: '/items/{item_id}', action: 'destroy', gateway: 'api' }
      result = test_class.infer_request_model_for_route(route, contract_names)
      expect(result).to be_nil
    end

    it 'handles nested resource paths' do
      contract_names_with_comment = Set.new(%w[create_comment update_comment])
      route = { verb: 'POST', path: '/posts/{post_id}/comments', action: 'create', gateway: 'api' }
      result = test_class.infer_request_model_for_route(route, contract_names_with_comment)
      expect(result).to eq('create_comment')
    end

    it 'singularizes plural resource names' do
      contract_names_with_pickup = Set.new(%w[create_pickup update_pickup])
      route = { verb: 'POST', path: '/pickups', action: 'create', gateway: 'api' }
      result = test_class.infer_request_model_for_route(route, contract_names_with_pickup)
      expect(result).to eq('create_pickup')
    end

    it 'handles hyphenated resource names' do
      contract_names_with_zone = Set.new(%w[create_coverage_zone])
      route = { verb: 'POST', path: '/coverage-zones', action: 'create', gateway: 'api' }
      result = test_class.infer_request_model_for_route(route, contract_names_with_zone)
      expect(result).to eq('create_coverage_zone')
    end
  end

  describe '#infer_response_model_for_route' do
    let(:response_contracts) { Set.new(%w[item customer pickup container]) }

    it 'infers response model from singular resource name' do
      route = { path: '/items', gateway: 'api' }
      result = test_class.infer_response_model_for_route(route, response_contracts)
      expect(result).to eq('item')
    end

    it 'works for member paths' do
      route = { path: '/items/{item_id}', gateway: 'api' }
      result = test_class.infer_response_model_for_route(route, response_contracts)
      expect(result).to eq('item')
    end

    it 'works for nested resource paths' do
      route = { path: '/posts/{post_id}/comments', gateway: 'api' }
      result = test_class.infer_response_model_for_route(route, response_contracts)
      expect(result).to be_nil # no 'comment' model defined
    end

    it 'returns nil when no matching model exists' do
      route = { path: '/widgets', gateway: 'api' }
      result = test_class.infer_response_model_for_route(route, response_contracts)
      expect(result).to be_nil
    end

    it 'singularizes plural resource names' do
      route = { path: '/customers', gateway: 'api' }
      result = test_class.infer_response_model_for_route(route, response_contracts)
      expect(result).to eq('customer')
    end

    it 'handles hyphenated paths' do
      response_contracts_with_zone = Set.new(%w[coverage_zone])
      route = { path: '/coverage-zones', gateway: 'api' }
      result = test_class.infer_response_model_for_route(route, response_contracts_with_zone)
      expect(result).to eq('coverage_zone')
    end
  end

  describe '#infer_request_models! (integration)' do
    it 'does not override explicitly set request_model' do
      routes = [
        { verb: 'POST', path: '/items', action: 'create', gateway: 'api',
          request_model: 'custom_create', response_model: '' }
      ]

      contracts = <<~RUBY
        Belt.application.schema.define do
          request :create_item do
            string :name
          end
        end
      RUBY

      tmpfile = Tempfile.new(['contracts', '.rb'])
      tmpfile.write(contracts)
      tmpfile.close

      test_class.infer_request_models!(routes, tmpfile.path)
      expect(routes.first[:request_model]).to eq('custom_create')
    ensure
      tmpfile.unlink
    end

    it 'fills in missing request_model from contracts' do
      routes = [
        { verb: 'POST', path: '/items', action: 'create', gateway: 'api',
          request_model: '', response_model: '' },
        { verb: 'PUT', path: '/items/{item_id}', action: 'update', gateway: 'api',
          request_model: '', response_model: '' }
      ]

      contracts = <<~RUBY
        Belt.application.schema.define do
          request :create_item do
            string :name
          end
          request :update_item do
            string :name
          end
        end
      RUBY

      tmpfile = Tempfile.new(['contracts', '.rb'])
      tmpfile.write(contracts)
      tmpfile.close

      Belt.instance_variable_set(:@application, nil)
      test_class.infer_request_models!(routes, tmpfile.path)

      expect(routes[0][:request_model]).to eq('create_item')
      expect(routes[1][:request_model]).to eq('update_item')
    ensure
      tmpfile.unlink
    end

    it 'fills in missing response_model from contracts' do
      routes = [
        { verb: 'GET', path: '/items', action: 'index', gateway: 'api',
          request_model: '', response_model: '' },
        { verb: 'GET', path: '/items/{item_id}', action: 'show', gateway: 'api',
          request_model: '', response_model: '' },
        { verb: 'POST', path: '/items', action: 'create', gateway: 'api',
          request_model: '', response_model: '' }
      ]

      contracts = <<~RUBY
        Belt.application.schema.define do
          model :item do
            context :api do
              string :id
              string :name
            end
          end
        end
      RUBY

      tmpfile = Tempfile.new(['contracts', '.rb'])
      tmpfile.write(contracts)
      tmpfile.close

      Belt.instance_variable_set(:@application, nil)
      test_class.infer_request_models!(routes, tmpfile.path)

      expect(routes[0][:response_model]).to eq('item')
      expect(routes[1][:response_model]).to eq('item')
      expect(routes[2][:response_model]).to eq('item')
    ensure
      tmpfile.unlink
    end

    it 'does not override explicitly set response_model' do
      routes = [
        { verb: 'GET', path: '/items', action: 'index', gateway: 'api',
          request_model: '', response_model: 'custom_response' }
      ]

      contracts = <<~RUBY
        Belt.application.schema.define do
          model :item do
            context :api do
              string :id
            end
          end
        end
      RUBY

      tmpfile = Tempfile.new(['contracts', '.rb'])
      tmpfile.write(contracts)
      tmpfile.close

      Belt.instance_variable_set(:@application, nil)
      test_class.infer_request_models!(routes, tmpfile.path)

      expect(routes.first[:response_model]).to eq('custom_response')
    ensure
      tmpfile.unlink
    end

    it 'infers both request_model and response_model together' do
      routes = [
        { verb: 'POST', path: '/items', action: 'create', gateway: 'api',
          request_model: '', response_model: '' }
      ]

      contracts = <<~RUBY
        Belt.application.schema.define do
          request :create_item do
            string :name
          end
          model :item do
            context :api do
              string :id
              string :name
            end
          end
        end
      RUBY

      tmpfile = Tempfile.new(['contracts', '.rb'])
      tmpfile.write(contracts)
      tmpfile.close

      Belt.instance_variable_set(:@application, nil)
      test_class.infer_request_models!(routes, tmpfile.path)

      expect(routes.first[:request_model]).to eq('create_item')
      expect(routes.first[:response_model]).to eq('item')
    ensure
      tmpfile.unlink
    end

    it 'prefers gateway-scoped request contracts' do
      routes = [
        { verb: 'POST', path: '/items', action: 'create', gateway: 'customer',
          request_model: '', response_model: '' }
      ]

      contracts = <<~RUBY
        Belt.application.schema.define do
          request :create_item do
            string :name
          end
          request :create_customer_item do
            string :name
          end
        end
      RUBY

      tmpfile = Tempfile.new(['contracts', '.rb'])
      tmpfile.write(contracts)
      tmpfile.close

      Belt.instance_variable_set(:@application, nil)
      test_class.infer_request_models!(routes, tmpfile.path)

      expect(routes.first[:request_model]).to eq('create_customer_item')
    ensure
      tmpfile.unlink
    end

    it 'skips non-body verbs for request_model' do
      routes = [
        { verb: 'GET', path: '/items', action: 'index', gateway: 'api',
          request_model: '', response_model: '' },
        { verb: 'DELETE', path: '/items/{item_id}', action: 'destroy', gateway: 'api',
          request_model: '', response_model: '' }
      ]

      contracts = <<~RUBY
        Belt.application.schema.define do
          request :create_item do
            string :name
          end
        end
      RUBY

      tmpfile = Tempfile.new(['contracts', '.rb'])
      tmpfile.write(contracts)
      tmpfile.close

      Belt.instance_variable_set(:@application, nil)
      test_class.infer_request_models!(routes, tmpfile.path)

      expect(routes[0][:request_model]).to eq('')
      expect(routes[1][:request_model]).to eq('')
    ensure
      tmpfile.unlink
    end

    it 'handles missing contracts file gracefully' do
      routes = [
        { verb: 'POST', path: '/items', action: 'create', gateway: 'api',
          request_model: '', response_model: '' }
      ]

      test_class.infer_request_models!(routes, '/nonexistent/contracts.rb')
      expect(routes.first[:request_model]).to eq('')
      expect(routes.first[:response_model]).to eq('')
    end
  end

  describe '#extract_singular_resource' do
    it 'singularizes the last non-param segment' do
      result = test_class.extract_singular_resource(path: '/items')
      expect(result).to eq('item')
    end

    it 'handles nested paths' do
      result = test_class.extract_singular_resource(path: '/posts/{post_id}/comments')
      expect(result).to eq('comment')
    end

    it 'handles member paths' do
      result = test_class.extract_singular_resource(path: '/items/{item_id}')
      expect(result).to eq('item')
    end

    it 'converts hyphens to underscores' do
      result = test_class.extract_singular_resource(path: '/coverage-zones')
      expect(result).to eq('coverage_zone')
    end
  end

  describe '#infer_verb_prefix' do
    it 'returns create for create action' do
      expect(test_class.infer_verb_prefix('POST', 'create')).to eq('create')
    end

    it 'returns update for update action' do
      expect(test_class.infer_verb_prefix('PUT', 'update')).to eq('update')
    end

    it 'returns create for POST with non-standard action' do
      expect(test_class.infer_verb_prefix('POST', 'signup')).to eq('create')
    end

    it 'returns update for PUT with non-standard action' do
      expect(test_class.infer_verb_prefix('PUT', 'assign')).to eq('update')
    end

    it 'returns nil for GET' do
      expect(test_class.infer_verb_prefix('GET', 'index')).to be_nil
    end

    it 'returns nil for DELETE' do
      expect(test_class.infer_verb_prefix('DELETE', 'destroy')).to be_nil
    end
  end
end
