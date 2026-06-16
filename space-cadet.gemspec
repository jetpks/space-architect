# frozen_string_literal: true

require_relative "lib/space_cadet/version"

Gem::Specification.new do |spec|
  spec.name = "space-cadet"
  spec.version = SpaceCadet::VERSION
  spec.authors = ["Eric Jacobs"]
  spec.email = ["eric@ebj.dev"]

  spec.summary = "Create and manage task-scoped project workspaces."
  spec.description = "A CLI for creating and managing filesystem-native project workspaces."
  spec.homepage = "https://github.com/jetpks/space-cadet"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt"]
  end
  spec.bindir = "exe"
  spec.executables = ["space"]
  spec.require_paths = ["lib"]

  spec.add_dependency "async", "~> 2.39"
  spec.add_dependency "async-process", "~> 1.4"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "thor", "~> 1.3"

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
