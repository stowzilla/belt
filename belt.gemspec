Gem::Specification.new do |spec|
  spec.name          = "belt"
  spec.version       = "0.0.1"
  spec.authors       = ["Stowzilla"]
  spec.email         = ["andy@stowzilla.com", "adam@stowzilla.com"]

  spec.summary       = "Belt - a utility toolkit for Ruby applications"
  spec.description   = "Belt provides a collection of lightweight utilities for Ruby applications."
  spec.homepage      = "https://github.com/stowzilla/belt"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md"]
  spec.require_paths = ["lib"]
end
