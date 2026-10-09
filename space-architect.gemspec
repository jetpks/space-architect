# frozen_string_literal: true

require_relative "lib/space_architect/version"

Gem::Specification.new do |spec|
  spec.name = "space-architect"
  spec.version = Space::Architect::VERSION
  spec.authors = ["Eric Jacobs"]
  spec.email = ["eric@ebj.dev"]

  spec.summary = "The Architect Loop — structured judgment-and-build cycles for humans and headless AI builders"
  spec.description = "A dry-cli CLI for the Architect Loop: iterations, briefs, freezes, verdicts, lane worktrees, and headless pi dispatch — the judgment loop that runs inside space-cadet's task-scoped workspaces. Depends on the space-cadet gem for the spaces substrate (hard) and the repo-tender gem for the session-sync launchd agent (soft, install at will)."
  spec.homepage = "https://github.com/jetpks/space-architect"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.5"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "lib/**/*.ts", "lib/**/*.erb", "exe/*", "skill/**/*", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  end
  spec.bindir = "exe"
  spec.executables = ["architect"]
  spec.require_paths = ["lib"]

  spec.add_dependency "space-cadet", "~> 9.1"
  spec.add_dependency "async-http", "~> 0.95"
  spec.add_dependency "async-process", "~> 1.4"
  spec.add_dependency "protocol-http", "~> 0.62"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "dry-cli", "~> 1.4"
  spec.add_dependency "dry-monads", "~> 1.10"
  spec.add_dependency "dry-validation", "~> 1.11"

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "mutant-minitest", "~> 0.16"
  spec.add_development_dependency "rake", "~> 13.0"
end
