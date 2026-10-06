# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'belt'
require 'belt/testing'

# A real gateway module + controllers so the harness exercises the genuine
# router -> controller resolution -> dispatch path (the whole point of the e2e tier).
module ApiControllers
  class ProjectsController < BeltController::Base
    def index
      success_response({ projects: [{ slug: 'alpha' }], caller: current_sub })
    end

    def show
      success_response({ project: { slug: params['project_id'] } })
    end

    def create
      success_response({ project: { slug: body['slug'] } }, :created)
    end

    private

    def current_sub
      event.dig('requestContext', 'authorizer', 'claims', 'sub')
    end
  end
end

RSpec.describe Belt::Testing::E2E do
  let(:routes) do
    [
      { verb: 'GET',  path: '/projects',              controller: 'projects', action: 'index' },
      { verb: 'GET',  path: '/projects/{project_id}', controller: 'projects', action: 'show' },
      { verb: 'POST', path: '/projects',              controller: 'projects', action: 'create' }
    ]
  end

  let(:router) { Belt::ActionRouter.new(routes: routes, gateway: 'api') }
  let(:client) { Belt::Testing::E2E::Client.new(router: router) }

  describe described_class::Response do
    it 'reports ok? for 2xx and not for others' do
      expect(described_class.new(status: 200).ok?).to be(true)
      expect(described_class.new(status: 299).ok?).to be(true)
      expect(described_class.new(status: 404).ok?).to be(false)
      expect(described_class.new(status: nil).ok?).to be(false)
    end

    it 'reads top-level keys out of the parsed body via []' do
      res = described_class.new(json: { 'project' => { 'slug' => 'x' } })
      expect(res['project']).to eq({ 'slug' => 'x' })
      expect(res[:project]).to eq({ 'slug' => 'x' })
    end
  end

  describe Belt::Testing::E2E::Client do
    it 'routes a GET through the real router and parses the response' do
      res = client.get('/projects')

      expect(res).to be_a(Belt::Testing::E2E::Response)
      expect(res.status).to eq(200)
      expect(res.ok?).to be(true)
      expect(res['projects']).to eq([{ 'slug' => 'alpha' }])
    end

    it 'extracts path params and hands them to the controller' do
      res = client.get('/projects/ws-42')
      expect(res.status).to eq(200)
      expect(res['project']).to eq({ 'slug' => 'ws-42' })
    end

    it 'passes the body hash straight through to the controller' do
      res = client.post('/projects', body: { 'slug' => 'beta' })
      expect(res.status).to eq(201)
      expect(res['project']).to eq({ 'slug' => 'beta' })
    end

    it 'injects claims into requestContext.authorizer.claims' do
      res = client.get('/projects', claims: { 'sub' => 'user-7' })
      expect(res.json['caller']).to eq('user-7')
    end

    it 'omits the authorizer when no claims are given' do
      res = client.get('/projects')
      expect(res.json['caller']).to be_nil
    end

    it 'sets a Bearer Authorization header when a token is given' do
      captured = nil
      allow(router).to receive(:route).and_wrap_original do |orig, event:, body:|
        captured = event['headers']
        orig.call(event: event, body: body)
      end

      client.get('/projects', token: 'fp_secret')
      expect(captured['Authorization']).to eq('Bearer fp_secret')
    end

    it 'passes query string parameters through on the event' do
      captured = nil
      allow(router).to receive(:route).and_wrap_original do |orig, event:, body:|
        captured = event['queryStringParameters']
        orig.call(event: event, body: body)
      end

      client.get('/projects', query: { 'page' => '2' })
      expect(captured).to eq({ 'page' => '2' })
    end

    it 'returns a Response for unmatched routes (router 404 path)' do
      res = client.delete('/nope')
      expect(res.status).to eq(404)
      expect(res.json['error']).to eq('Not found')
    end

    it 'tolerates a non-JSON / empty body without raising' do
      allow(router).to receive(:route).and_return({ statusCode: 204, headers: {}, body: '' })
      empty = client.get('/projects')
      expect(empty.status).to eq(204)
      expect(empty.json).to be_nil
    end
  end

  describe '.parse_manifest' do
    it 'maps belt routes JSON into the router manifest shape' do
      json = JSON.generate(
        routes: [
          { verb: 'GET', path: '/x', controller: 'xs', action: 'index', auth: 'cognito', tables: ['xs'] }
        ]
      )

      expect(described_class.parse_manifest(json)).to eq(
        [{ verb: 'GET', path: '/x', controller: 'xs', action: 'index' }]
      )
    end

    it 'raises a Belt::Testing::E2E::Error when the routes key is missing' do
      expect { described_class.parse_manifest('{}') }
        .to raise_error(Belt::Testing::E2E::Error, /missing expected key/)
    end
  end

  describe '.manifest_from_belt_routes' do
    it 'shells out, parses, and returns the manifest on success' do
      json = JSON.generate(routes: [{ verb: 'GET', path: '/x', controller: 'xs', action: 'index' }])
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      allow(Open3).to receive(:capture3).and_return([json, '', status])

      result = described_class.manifest_from_belt_routes(app_root: '/tmp/app')
      expect(result).to eq([{ verb: 'GET', path: '/x', controller: 'xs', action: 'index' }])
    end

    it 'raises with stderr when the command fails' do
      status = instance_double(Process::Status, success?: false, exitstatus: 1)
      allow(Open3).to receive(:capture3).and_return(['', 'boom', status])

      expect { described_class.manifest_from_belt_routes(app_root: '/tmp/app') }
        .to raise_error(Belt::Testing::E2E::Error, /failed \(1\): boom/)
    end
  end

  describe Belt::Testing::E2E::Helpers do
    let(:harness) do
      Class.new do
        include Belt::Testing::E2E::Helpers

        attr_writer :e2e_client

        attr_reader :e2e_client
      end.new
    end

    before { harness.e2e_client = client }

    it 'delegates api_* helpers to the client' do
      expect(harness.api_get('/projects').status).to eq(200)
      expect(harness.api_post('/projects', body: { 'slug' => 'z' })['project']).to eq({ 'slug' => 'z' })
    end

    it 'builds Cognito claims with groups joined for arrays' do
      claims = harness.cognito_claims(sub: 'u1', groups: %w[admins editors], tenant: 't1')
      expect(claims['sub']).to eq('u1')
      expect(claims['cognito:groups']).to eq('admins editors')
      expect(claims['tenant']).to eq('t1')
    end

    it 'omits groups and email when not provided' do
      claims = harness.cognito_claims(email: nil)
      expect(claims).to eq({ 'sub' => 'e2e-user-sub' })
    end

    it 'falls back to the process-wide client when #e2e_client is not overridden' do
      default_harness = Class.new { include Belt::Testing::E2E::Helpers }.new
      Belt::Testing::E2E.client = client
      begin
        expect(default_harness.api_get('/projects').status).to eq(200)
      ensure
        Belt::Testing::E2E.client = nil
      end
    end

    it 'raises a clear error when no client is configured' do
      bare = Class.new { include Belt::Testing::E2E::Helpers }.new
      Belt::Testing::E2E.client = nil
      expect { bare.api_get('/projects') }
        .to raise_error(Belt::Testing::E2E::Error, /No Belt::Testing::E2E client configured/)
    end
  end
end
