# frozen_string_literal: true

require 'active_support/core_ext/string/inflections'
require 'active_support/inflector'

# Add common inflection rules that ActiveSupport doesn't include by default
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.irregular 'hero', 'heroes'
  inflect.irregular 'potato', 'potatoes'
  inflect.irregular 'volcano', 'volcanoes'
  inflect.irregular 'echo', 'echoes'
  inflect.irregular 'embargo', 'embargoes'
  inflect.irregular 'veto', 'vetoes'
end

module Belt
  # Provides proper English inflection rules (pluralize, singularize, classify, etc.)
  # via ActiveSupport::Inflector. Used throughout Belt for resource name derivation.
  #
  # ActiveSupport is already a transitive dependency (via activeitem → activemodel → activesupport)
  # so this adds zero new weight.
  module Inflector
    module_function

    # "hero" → "heroes", "post" → "posts", "person" → "people"
    def pluralize(word)
      word.to_s.pluralize
    end

    # "heroes" → "hero", "posts" → "post", "people" → "person"
    def singularize(word)
      word.to_s.singularize
    end

    # "blog_post" → "BlogPost", "hero" → "Hero"
    def classify(word)
      singularize(word).split('_').map(&:capitalize).join
    end

    # "blog_posts" → "BlogPosts", "heroes" → "Heroes" (no singularization)
    def camelize(word)
      word.to_s.split('_').map(&:capitalize).join
    end

    # "conversation_id" → "conversationId"
    def camelize_lower(word)
      parts = word.to_s.split('_')
      return word if parts.empty?

      parts.first + parts[1..].map(&:capitalize).join
    end

    # "BlogPost" → "blog_post"
    def underscore(word)
      word.to_s
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
    end

    # "heroes_controller" → "heroes", "PostsController" → "posts"
    def resource_name(word)
      pluralize(word.to_s.sub(/_?controller$/i, '').downcase)
    end
  end
end
