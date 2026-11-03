# frozen_string_literal: true

require 'activeitem'
require_relative '../inflector'

module Belt
  module Models
    # Declares the DynamoDB Time To Live attribute for a model's table:
    #
    #   class Session < ApplicationRecord
    #     ttl_attribute :expires_at   # → ttl { attribute_name = "expiresAt" }
    #   end
    #
    # DynamoDB does the expiring, so at runtime this only records the name. The point
    # is that `belt setup tables` reads it and emits the `ttl { }` block — a block
    # added straight into dynamodb.tf would be dropped by the next regeneration.
    #
    # A symbol is camelCased the way ActiveItem stores it (`:expires_at` → `expiresAt`).
    # Pass a string to use the DynamoDB attribute name verbatim (e.g. when the model
    # remaps it with dynamo_attribute_map).
    module TtlMacro
      def ttl_attribute(name = nil)
        return @ttl_attribute if name.nil?

        @ttl_attribute = name.is_a?(Symbol) ? Belt::Inflector.camelize_lower(name.to_s) : name.to_s
      end
    end
  end
end

ActiveItem::Base.extend(Belt::Models::TtlMacro)
