# frozen_string_literal: true

require 'json'

module Belt
  module Testing
    # In-process end-to-end harness — the real request path, no AWS.
    #
    # Most backend tests stop at the controller: they instantiate a controller and
    # dispatch an action directly. That proves action logic, but it never exercises the
    # router, the route manifest, path-param extraction, or the Lambda-shaped event the
    # controller actually receives in production.
    #
    # This harness closes that gap. It drives the REAL {Belt::ActionRouter} with a
    # synthetic API Gateway proxy event — method, path, body, and a requestContext
    # carrying Cognito-style claims — exactly as API Gateway would deliver it. The router
    # finds the route, extracts path params, instantiates the real controller, and runs
    # the real before_action chain. You assert on the HTTP-shaped response.
    #
    # What's real vs. seamed (the deliberate boundary):
    #   - Router, controllers, models, validations, authorization .... REAL
    #   - DynamoDB ............................................ your choice (e.g. DynamoDB Local)
    #   - Cognito ............................................ a claims hash in requestContext
    #                                                          (the seam API Gateway's
    #                                                          authorizer fills in production)
    #   - API Gateway ........................................ the synthetic event IS the seam
    #
    # The harness is framework-agnostic: use the {Client} directly, or mix {Helpers}
    # into your Minitest::Test / RSpec example group for `api_get`/`api_post`/... sugar.
    #
    # @example Minitest
    #   router = Belt::ActionRouter.new(
    #     routes: Belt::Testing::E2E.manifest_from_belt_routes(app_root: APP_ROOT),
    #     gateway: 'api'
    #   )
    #   Belt::Testing::E2E.client = Belt::Testing::E2E::Client.new(router: router)
    #
    #   class ProjectsE2ETest < Minitest::Test
    #     include Belt::Testing::E2E::Helpers
    #
    #     def test_create_project
    #       res = api_post('/projects', body: { slug: 'x' }, claims: cognito_claims(groups: 'admins'))
    #       assert res.ok?
    #       assert_equal 'x', res['project']['slug']
    #     end
    #   end
    module E2E
      # A parsed response from the router. `json` is the body parsed as JSON (Hash) when
      # possible; `[]` reads a top-level key out of that parsed body.
      Response = Struct.new(:status, :headers, :body, :json, keyword_init: true) do
        def ok?
          status.is_a?(Integer) && status.between?(200, 299)
        end

        def [](key)
          json&.[](key.to_s)
        end
      end

      class << self
        # A process-wide default client, so {Helpers} works without per-test setup.
        # Assign one after booting your stack and building a router.
        attr_accessor :client

        # Build a route manifest from the app's own `belt routes -f json`.
        #
        # This is the app's canonical, supported way to produce a manifest — the same
        # path the deployed Lambda's manifest comes from — so the harness can't drift
        # from Belt's route-building internals.
        #
        # @param app_root [String] directory to run `belt routes` from (the app's `lambda/`)
        # @param command [Array<String>] override the command (mainly for testing)
        # @return [Array<Hash>] routes shaped as { verb:, path:, controller:, action: }
        def manifest_from_belt_routes(app_root:, command: %w[bundle exec belt routes -f json])
          require 'open3'
          out, err, status = Open3.capture3(*command, chdir: app_root)
          raise Error, "`#{command.join(' ')}` failed (#{status.exitstatus}): #{err.strip}" unless status.success?

          parse_manifest(out)
        end

        # Parse the JSON produced by `belt routes -f json` into the manifest shape the
        # router expects. Public so callers that already have the JSON (CI artifact,
        # cached file) can reuse it without shelling out.
        #
        # @param json [String] output of `belt routes -f json`
        # @return [Array<Hash>]
        def parse_manifest(json)
          JSON.parse(json).fetch('routes').map do |r|
            {
              verb: r['verb'],
              path: r['path'],
              controller: r['controller'],
              action: r['action']
            }
          end
        rescue KeyError => e
          raise Error, "belt routes JSON missing expected key: #{e.message}"
        end
      end

      # Raised when the harness can't do its job (manifest load failure, missing client).
      class Error < StandardError; end

      # Drives a {Belt::ActionRouter} with synthetic API Gateway proxy events.
      #
      # One client wraps one router. Build it once per process (routing is immutable) and
      # reuse it across tests — isolation comes from your data-store teardown, not from
      # rebuilding the router.
      class Client
        attr_reader :router

        # @param router [Belt::ActionRouter] the real router to dispatch through
        def initialize(router:)
          @router = router
        end

        # Issue a request through the real router.
        #
        # @param method [Symbol, String] HTTP verb (:get, :post, ...)
        # @param path [String] request path, e.g. '/projects/ws-1'
        # @param body [Hash, nil] request body, already parsed (as the LambdaHandler
        #   delivers it in production). `nil` becomes `{}` inside the controller.
        # @param claims [Hash, nil] Cognito claims the API Gateway authorizer would inject
        #   into `requestContext.authorizer.claims`. `nil` means an unauthenticated request.
        # @param token [String, nil] a Bearer token (e.g. an API key) set as the
        #   Authorization header, for non-Cognito auth paths.
        # @param headers [Hash] extra request headers.
        # @param query [Hash, nil] query string parameters.
        # @return [Response]
        # rubocop:disable Metrics/ParameterLists -- these are the request's distinct, documented dimensions
        def request(method, path, body: nil, claims: nil, token: nil, headers: {}, query: nil)
          # rubocop:enable Metrics/ParameterLists
          event = {
            'httpMethod' => method.to_s.upcase,
            'path' => path,
            'headers' => build_headers(headers, token),
            'pathParameters' => {},
            'queryStringParameters' => query,
            'requestContext' => request_context(claims)
          }

          result = router.route(event: event, body: body)
          parse_response(result)
        end

        def get(path, **)    = request(:get, path, **)
        def post(path, **)   = request(:post, path, **)
        def put(path, **)    = request(:put, path, **)
        def patch(path, **)  = request(:patch, path, **)
        def delete(path, **) = request(:delete, path, **)

        private

        def build_headers(headers, token)
          h = (headers || {}).dup
          h['Authorization'] = "Bearer #{token}" if token
          h
        end

        def request_context(claims)
          return {} if claims.nil?

          { 'authorizer' => { 'claims' => claims } }
        end

        # The real controller always returns a Lambda-shaped Hash:
        # { statusCode:, headers:, body: <JSON string> }. So does the router's own error
        # path. Normalize into a Response, tolerating string or symbol keys.
        def parse_response(result)
          status  = result[:statusCode] || result['statusCode']
          headers = result[:headers] || result['headers'] || {}
          raw     = result[:body] || result['body']

          json =
            begin
              raw.is_a?(String) && !raw.empty? ? JSON.parse(raw) : nil
            rescue JSON::ParserError
              nil
            end

          Response.new(status: status, headers: headers, body: raw, json: json)
        end
      end

      # Mixin for test classes (Minitest::Test or RSpec example groups).
      #
      # Provides `api_get`/`api_post`/`api_put`/`api_patch`/`api_delete`/`api_request`
      # delegating to a client, plus a `cognito_claims` builder. By default it uses the
      # process-wide {E2E.client}; override {#e2e_client} to supply a per-test client.
      module Helpers
        # The client requests route through. Override in your test base class to use a
        # different client than the process-wide default.
        #
        # @return [Client]
        def e2e_client
          E2E.client || raise(Error, 'No Belt::Testing::E2E client configured. ' \
                                     'Set Belt::Testing::E2E.client or override #e2e_client.')
        end

        def api_request(method, path, **) = e2e_client.request(method, path, **)
        def api_get(path, **)             = e2e_client.get(path, **)
        def api_post(path, **)            = e2e_client.post(path, **)
        def api_put(path, **)             = e2e_client.put(path, **)
        def api_patch(path, **)           = e2e_client.patch(path, **)
        def api_delete(path, **)          = e2e_client.delete(path, **)

        # Build a Cognito claims hash — what API Gateway's authorizer injects for an
        # authenticated human.
        #
        # @param sub [String] the Cognito subject (user id)
        # @param email [String, nil] the user's email claim
        # @param groups [String, Array<String>, nil] `cognito:groups` (platform roles).
        #   Belt reads this as a space/comma-delimited string; an array is joined with ' '.
        # @param extra [Hash] any additional claims to merge in
        # @return [Hash]
        def cognito_claims(sub: 'e2e-user-sub', email: 'user@example.com', groups: nil, **extra)
          claims = { 'sub' => sub }
          claims['email'] = email if email
          claims['cognito:groups'] = groups.is_a?(Array) ? groups.join(' ') : groups if groups
          claims.merge(extra.transform_keys(&:to_s))
        end
      end
    end
  end
end
