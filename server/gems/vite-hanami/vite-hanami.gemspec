# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name    = "vite-hanami"
  spec.version = "0.1.0"
  spec.authors = ["eric jacobs"]
  spec.summary = "Vite asset tag helpers for Hanami 2.x — thin binding over vite_ruby 3.x"
  spec.files   = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 4.0"

  spec.add_dependency "vite_ruby", "~> 3.10"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
end
