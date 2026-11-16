# frozen_string_literal: true

require 'spec_helper'

class SpecAuthController < BeltController::Base
  def show
    @user = current_user
  end
end

class SpecAuthGuardedController < BeltController::Base
  before_action :authenticate_user!

  def show
    @ok = true
  end
end

RSpec.describe Belt::Authentication::Controller do
  let(:user_model) do
    Class.new do
      class << self
        attr_accessor :last_claims

        def sync_from_claims!(**claims)
          self.last_claims = claims
          claims[:sub] ? new(claims) : nil
        end

        def name
          'SpecControllerUser'
        end
      end

      attr_reader :claims

      def initialize(claims)
        @claims = claims
      end
    end
  end

  before do
    stub_const('SpecControllerUser', user_model)
    Belt.configuration.authentication.user_class = 'SpecControllerUser'
  end

  after { Belt.reset_configuration! }

  def controller(event, klass: SpecAuthController)
    klass.new(event: event, body: {})
  end

  def authorizer_event(claims)
    { 'requestContext' => { 'authorizer' => { 'claims' => claims } } }
  end

  describe '#cognito_claims' do
    it 'resolves once per request' do
      subject = controller(authorizer_event('sub' => 'abc'))

      expect(subject.cognito_claims).to be(subject.cognito_claims)
    end

    it 'is nil for an anonymous request' do
      expect(controller({}).cognito_claims).to be_nil
    end
  end

  # A route without an API Gateway authorizer has nothing in front of it. A token the
  # caller made up — right issuer, right client, admin group — must not be believed.
  describe 'a forged Bearer token on a route with no authorizer' do
    let(:issuer) { 'https://cognito-idp.us-east-1.amazonaws.com/us-east-1_pool' }
    let(:pool_key) { OpenSSL::PKey::RSA.new(2048) }
    let(:claims) do
      { 'sub' => 'victim-sub', 'email' => 'victim@example.com', 'cognito:groups' => ['admins'],
        'iss' => issuer, 'aud' => 'client-1', 'token_use' => 'id', 'exp' => Time.now.to_i + 600 }
    end

    before do
      Belt.configuration.authentication.issuer = issuer
      Belt.configuration.authentication.client_ids = ['client-1']
      Belt::Authentication::TokenVerifier.store_keys(issuer, 'kid-1' => pool_key.public_key)
    end

    after { Belt::Authentication::TokenVerifier.reset! }

    def token(signature)
      header = Base64.urlsafe_encode64('{"alg":"RS256","kid":"kid-1"}', padding: false)
      payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
      "#{header}.#{payload}.#{Base64.urlsafe_encode64(signature.call("#{header}.#{payload}"), padding: false)}"
    end

    def header_event(token)
      { 'headers' => { 'Authorization' => "Bearer #{token}" } }
    end

    it 'is nobody: no claims, no user, no admin, and nothing written to the model' do
      expect(SpecControllerUser).not_to receive(:sync_from_claims!)
      subject = controller(header_event(token(->(_signed) { 'made-up-signature' })))

      expect(subject.cognito_claims).to be_nil
      expect(subject.current_user).to be_nil
      expect(subject).not_to be_cognito_admin
      expect { subject.authenticate_user! }.to raise_error(Belt::Authentication::NotAuthenticated)
    end

    it 'is nobody when the app has no pool configured, even with a real signature' do
      Belt.configuration.authentication.issuer = nil
      subject = controller(header_event(token(->(signed) { pool_key.sign('SHA256', signed) })))

      expect(subject.current_user).to be_nil
      expect(subject).not_to be_cognito_admin
    end

    it "is the user when the token really was signed by the app's pool" do
      subject = controller(header_event(token(->(signed) { pool_key.sign('SHA256', signed) })))

      expect(subject.current_user.claims).to include(sub: 'victim-sub', admin: true)
    end
  end

  describe '#cognito_admin?' do
    it 'is true for a member of the configured staff group' do
      subject = controller(authorizer_event('sub' => 'abc', 'cognito:groups' => 'admins'))

      expect(subject).to be_cognito_admin
    end

    it 'is false for a member of some other group' do
      subject = controller(authorizer_event('sub' => 'abc', 'cognito:groups' => '[members]'))

      expect(subject).not_to be_cognito_admin
    end

    it 'follows the configured group names' do
      Belt.configuration.authentication.admin_groups = %w[staff]
      subject = controller(authorizer_event('sub' => 'abc', 'cognito:groups' => 'staff'))

      expect(subject).to be_cognito_admin
    end

    # An anonymous request has no groups, so it is never staff. Guards the
    # [].intersect? path — an empty group list must answer false, not raise.
    it 'is false for an anonymous request' do
      expect(controller({})).not_to be_cognito_admin
    end

    it 'is false for a token carrying no groups claim' do
      subject = controller(authorizer_event('sub' => 'abc'))

      expect(subject).not_to be_cognito_admin
      expect(subject.cognito_groups).to eq([])
    end
  end

  describe '#current_user' do
    it 'provisions from the claims on the request' do
      subject = controller(authorizer_event('sub' => 'abc', 'email' => 'a@b.com', 'name' => 'Ada'))

      expect(subject.current_user.claims).to include(sub: 'abc', email: 'a@b.com', name: 'Ada')
    end

    it 'passes the staff group through as admin' do
      subject = controller(authorizer_event('sub' => 'abc', 'cognito:groups' => 'admins'))
      subject.current_user

      expect(SpecControllerUser.last_claims[:admin]).to be(true)
    end

    it 'is nil for an anonymous request, without touching the model' do
      expect(SpecControllerUser).not_to receive(:sync_from_claims!)

      expect(controller({}).current_user).to be_nil
    end

    # An app credential that isn't a Cognito token reads as "no Cognito identity".
    it 'is nil for a non-JWT bearer token' do
      subject = controller({ 'headers' => { 'Authorization' => 'Bearer fp_live_abc' } })

      expect(subject.current_user).to be_nil
    end

    it 'is nil when the app has no user model' do
      Belt.configuration.authentication.user_class = 'NoSuchUserModel'

      expect(controller(authorizer_event('sub' => 'abc')).current_user).to be_nil
    end

    # An app with its own credential scheme can declare "this caller is not a human"
    # even when the request could also be read as Cognito.
    it 'is nil when the app skips Cognito identity for this request' do
      klass = Class.new(BeltController::Base) do
        def skip_cognito_identity?
          true
        end
      end

      expect(SpecControllerUser).not_to receive(:sync_from_claims!)
      expect(controller(authorizer_event('sub' => 'abc'), klass: klass).current_user).to be_nil
    end

    it 'resolves once per request' do
      subject = controller(authorizer_event('sub' => 'abc'))

      expect(subject.current_user).to be(subject.current_user)
    end

    # Underscore-prefixed so Belt's implicit-response serializer never leaks an
    # identity into a JSON body.
    it 'does not leak the identity into an implicit response' do
      subject = controller(authorizer_event('sub' => 'abc'))
      response = subject.dispatch(:show)
      body = JSON.parse(response[:body])

      expect(body.keys).to eq(['user'])
    end
  end

  describe '#authenticate_user!' do
    it 'lets an authenticated request through' do
      response = controller(authorizer_event('sub' => 'abc'), klass: SpecAuthGuardedController).dispatch(:show)

      expect(response[:statusCode]).to eq(200)
    end

    it 'halts an anonymous request with a 401' do
      response = controller({}, klass: SpecAuthGuardedController).dispatch(:show)

      expect(response[:statusCode]).to eq(401)
      expect(JSON.parse(response[:body])).to include('error' => 'Authentication required')
    end

    it 'raises an error Belt already maps to 401' do
      expect(Belt::Authentication::NotAuthenticated.ancestors).to include(Belt::AuthenticationError)
    end
  end
end
