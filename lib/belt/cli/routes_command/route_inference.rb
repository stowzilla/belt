# frozen_string_literal: true

module Belt
  module CLI
    class RoutesCommand
      # Extracts route controller/action inference logic from RoutesCommand.
      module RouteInference
        private

        def infer_controller(route, gateway)
          return route.controller.to_s if route.controller

          segments = route.path.split('/').reject(&:empty?)
          non_param = segments.reject { |s| s.start_with?(':', '{') }
          return gateway.name if non_param.empty?

          return non_param.map { |s| s.gsub('-', '_') }.join('/') if route.resource? && nested_resource?(segments)

          non_param.first.gsub('-', '_')
        end

        def infer_action(route, _gateway)
          return route.action.to_s if route.action

          segments = route.path.split('/').reject(&:empty?)
          verb = route.method

          if route.singular_resource?
            infer_singular_resource_action(verb)
          elsif route.plural_resource?
            infer_plural_resource_action(verb, segments)
          else
            infer_plain_action(verb, segments)
          end
        end

        def infer_singular_resource_action(verb)
          case verb
          when 'GET' then 'show'
          when 'PUT', 'PATCH' then 'update'
          when 'DELETE' then 'destroy'
          when 'POST' then 'create'
          else 'show'
          end
        end

        def infer_plural_resource_action(verb, segments)
          has_id = segments.any? { |s| s.start_with?(':', '{') }
          last_is_param = segments.last&.start_with?(':', '{')

          if nested_resource?(segments)
            child_idx = segments.rindex { |s| !s.start_with?(':', '{') }
            has_child_id = child_idx && segments[(child_idx + 1)..]&.any? { |s| s.start_with?(':', '{') }
            restful_action(verb, has_child_id || false)
          else
            restful_action(verb, has_id && last_is_param)
          end
        end

        def infer_plain_action(verb, segments)
          non_param = segments.reject { |s| s.start_with?(':', '{') }
          has_id = segments.any? { |s| s.start_with?(':', '{') }
          last_is_param = segments.last&.start_with?(':', '{')

          if non_param.length <= 1 && !has_id
            non_param.first&.gsub('-', '_') || 'index'
          elsif non_param.length > 1
            non_param.last.gsub('-', '_')
          else
            restful_action(verb, has_id && last_is_param)
          end
        end

        def nested_resource?(segments)
          segments.length >= 3 &&
            !segments[0].start_with?(':', '{') &&
            segments[1]&.start_with?(':', '{') &&
            !segments[2]&.start_with?(':', '{')
        end

        def restful_action(verb, is_member)
          case [verb, is_member]
          when ['GET', false] then 'index'
          when ['GET', true] then 'show'
          when ['POST', false] then 'create'
          when ['PUT', true], ['PATCH', true] then 'update'
          when ['DELETE', true] then 'destroy'
          else 'index'
          end
        end
      end
    end
  end
end
