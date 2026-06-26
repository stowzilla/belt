# frozen_string_literal: true

require_relative 'lib/belt/version'

Gem::Specification.new do |spec|
  spec.name          = 'belt'
  spec.version       = Belt::VERSION
  spec.authors       = ['Stowzilla']
  spec.email         = ['andy@stowzilla.com', 'adam@stowzilla.com']

  spec.summary       = 'Belt - a utility toolkit for Ruby applications'
  spec.description   = 'Belt provides a collection of lightweight utilities for Ruby applications.'
  spec.homepage      = 'https://github.com/stowzilla/belt'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'exe/*', 'LICENSE.txt', 'README.md', 'CHANGELOG.md']
  spec.bindir = 'exe'
  spec.executables = ['belt']
  spec.require_paths = ['lib']

  spec.add_dependency 'activeitem', '~> 0.0'
  spec.add_dependency 'lambda_loadout', '~> 0.0'
end
