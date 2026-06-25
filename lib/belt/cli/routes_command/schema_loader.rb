# frozen_string_literal: true

module Belt
  module CLI
    class RoutesCommand
      # Extracts schema model loading logic from RoutesCommand.
      module SchemaLoader
        private

        def load_schema_models(routes_file)
          schema_file = resolve_schema_file(routes_file)
          return [] unless schema_file && File.exist?(schema_file)

          Belt.instance_variable_set(:@application, nil)
          begin
            eval(File.read(schema_file), binding, schema_file) # rubocop:disable Security/Eval
          rescue StandardError => e
            warn "Warning: Failed to load schema file #{schema_file}: #{e.message}"
            return []
          end

          schema = Belt.application.schema.to_h
          build_models_from_schema(schema)
        end

        def resolve_schema_file(routes_file)
          schema_file = @options[:schema_file]
          unless schema_file
            routes_dir = File.dirname(File.expand_path(routes_file))
            schema_file = File.join(routes_dir, 'schema.tf.rb')
          end
          schema_file
        end

        def build_models_from_schema(schema)
          models = []

          (schema[:request_models] || {}).each_value do |model|
            models << {
              name: model[:name],
              kind: 'request',
              description: "Request model: #{model[:name]}",
              properties: stringify_properties(model[:properties] || {}),
              required: (model[:required] || []).map(&:to_s)
            }
          end

          (schema[:response_models] || {}).each_value do |model|
            (model[:contexts] || {}).each do |ctx_name, ctx|
              models << {
                name: "#{model[:name]}_#{ctx_name}_response",
                kind: 'response',
                description: "Response model: #{model[:name]} (#{ctx_name} context)",
                properties: stringify_properties(ctx[:properties] || {}),
                required: []
              }
            end
          end

          models
        end

        def stringify_properties(properties)
          properties.each_with_object({}) do |(key, value), hash|
            hash[key.to_s] = value.transform_keys(&:to_s)
          end
        end
      end
    end
  end
end
