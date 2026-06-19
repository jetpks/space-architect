# frozen_string_literal: true

require_relative "lib/space_cadet/version"

Gem::Specification.new do |spec|
  spec.name = "space-cadet"
  spec.version = SpaceCadet::VERSION
  spec.authors = ["Eric Jacobs"]
  spec.email = ["eric@ebj.dev"]

  spec.summary = "Task-scoped project workspaces (repos · notes · artifacts under one self-describing root)"
  spec.description = "A dry-cli CLI for spaces: date-prefixed directories with a YAML identity file, $PWD-based current-space resolution, and XDG config/state. Provisions repos at copy-on-write speed from evergreen checkouts (pairs with repo-tender), concurrently on fibers. Ships fish shell integration and completions."
  spec.homepage = "https://github.com/jetpks/space-cadet"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "lib/**/*.erb", "exe/*", "README.md", "LICENSE.txt"]
  end
  spec.bindir = "exe"
  spec.executables = ["space"]
  spec.require_paths = ["lib"]

  spec.add_dependency "async", "~> 2.39"
  spec.add_dependency "async-process", "~> 1.4"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "dry-cli", "~> 1.4"

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
