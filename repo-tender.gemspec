# frozen_string_literal: true

require_relative "lib/repo_tender/version"

Gem::Specification.new do |spec|
  spec.name = "repo-tender"
  spec.version = RepoTender::VERSION
  spec.authors = ["jetpks"]
  spec.summary = "Keep local git clones evergreen (clean · on default branch · fetched within refresh_interval)"
  spec.description = "A dry-cli binary plus a periodic launchd-invoked sync sweep. macOS-only, GitHub-only (behind decoupled SCM/forge interfaces). Never mutates a dirty/diverged repo."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.5"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "bin/**/*", "README.md", "LICENSE.txt", "repo-tender.gemspec"].select { |f| File.file?(f) }
  end
  spec.require_paths = ["lib"]
  spec.bindir = "bin"
  spec.executables = ["repo-tender"]

  spec.add_dependency "async", "~> 2.39"
  spec.add_dependency "dry-cli", "~> 1.4"
  spec.add_dependency "dry-monads", "~> 1.10"
  spec.add_dependency "dry-schema", "~> 1.16"
  spec.add_dependency "dry-struct", "~> 1.8"
  spec.add_dependency "dry-types", "~> 1.9"
  spec.add_dependency "dry-validation", "~> 1.11"
  spec.add_dependency "xdg", "~> 10.2"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "tty-cursor", "~> 0.7"
  spec.add_dependency "tty-screen", "~> 0.8"
end
