# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Belt::Authentication::SessionCookie::Pkce do
  it 'derives an S256 challenge that matches its verifier' do
    verifier = described_class.verifier
    challenge = described_class.challenge(verifier)
    expect(described_class.matches?(verifier: verifier, challenge: challenge)).to be(true)
  end

  it 'rejects a mismatched verifier' do
    challenge = described_class.challenge(described_class.verifier)
    expect(described_class.matches?(verifier: 'someone elses verifier', challenge: challenge)).to be(false)
  end

  it 'produces url-safe, unpadded challenges' do
    challenge = described_class.challenge('verifier')
    expect(challenge).not_to include('=', '+', '/')
  end

  it 'mints high-entropy verifiers within the RFC 7636 length range' do
    expect(described_class.verifier.length).to be_between(43, 128)
  end
end
