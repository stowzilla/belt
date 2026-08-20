# frozen_string_literal: true

module Belt
  module CLI
    class RoutesCommand
      # Infers request_model from contracts using naming conventions.
      #
      # Convention cascade (first match wins):
      #   1. :<verb>_<gateway>_<singular_resource>  (e.g. :create_customer_item)
      #   2. :<verb>_<singular_resource>            (e.g. :create_item)
      #
      # Only applies to body-accepting verbs (POST/PUT/PATCH) on resource routes.
      # Explicit request_model always wins — inference only fills in blanks.
      module RequestModelInference
        private

        # Applies convention-based request_model inference to all routes.
        # Requires the set of known contract names from contracts.rb.
        def infer_request_models!(routes, contracts_file)
          contract_names = load_contract_names(contracts_file)
          return if contract_names.empty?

          routes.each do |route|
            next unless route[:request_model].to_s.empty?
            next unless body_accepting_verb?(route[:verb])

            inferred = infer_request_model_for_route(route, contract_names)
            route[:request_model] = inferred if inferred
          end
        end

        def load_contract_names(contracts_file)
          return Set.new unless contracts_file && File.exist?(contracts_file)

          # Reset application state for clean contract loading
          Belt.instance_variable_set(:@application, nil)
          begin
            eval(File.read(contracts_file), binding, contracts_file) # rubocop:disable Security/Eval
          rescue StandardError => e
            warn "Warning: Failed to load contracts for inference: #{e.message}"
            return Set.new
          end

          schema = Belt.application.schema.to_h
          names = Set.new
          (schema[:request_models] || {}).each_key { |name| names << name.to_s }
          names
        end

        def infer_request_model_for_route(route, contract_names)
          verb_prefix = infer_verb_prefix(route[:verb], route[:action])
          return nil unless verb_prefix

          resource_name = extract_singular_resource(route)
          return nil unless resource_name

          gateway = route[:gateway]

          # Cascade: gateway-scoped first, then generic
          candidates = [
            "#{verb_prefix}_#{gateway}_#{resource_name}",
            "#{verb_prefix}_#{resource_name}"
          ]

          candidates.find { |candidate| contract_names.include?(candidate) }
        end

        def infer_verb_prefix(verb, action)
          # Map HTTP verb + action to the contract naming prefix
          case action
          when 'create' then 'create'
          when 'update' then 'update'
          else
            # For non-standard actions on body verbs, don't infer
            case verb
            when 'POST' then 'create'
            when 'PUT', 'PATCH' then 'update'
            end
          end
        end

        def extract_singular_resource(route)
          # Extract the resource name from the path
          segments = route[:path].split('/').reject(&:empty?)
          # Find the last non-param segment that looks like a resource
          resource_segments = segments.reject { |s| s.start_with?('{', ':') }
          return nil if resource_segments.empty?

          resource = resource_segments.last
          Belt::Inflector.singularize(resource.gsub('-', '_'))
        end

        def body_accepting_verb?(verb)
          %w[POST PUT PATCH].include?(verb)
        end
      end
    end
  end
end
