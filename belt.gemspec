# frozen_string_literal: true

require_relative "lib/belt/version"

Gem::Specification.new do |spec|
  spec.name          = "belt"
  spec.version       = Belt::VERSION
  spec.authors       = ["Stowzilla"]
  spec.email         = ["andy@stowzilla.com", "adam@stowzilla.com"]

  spec.summary       = "Serverless Ruby framework for AWS Lambda"
  spec.description   = "Belt is a Rails-inspired framework for building serverless Ruby applications " \
                       "on AWS Lambda. Includes controllers, strong parameters, structured logging, " \
                       "DynamoDB ORM, and full-text search — everything you need to go from zero to production."
  spec.homepage      = "https://github.com/stowzilla/belt"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activeitem", "~> 0.0"
  spec.add_dependency "lambda_loadout", "~> 0.0"
  spec.add_dependency "s3arch", "~> 0.0"
end
