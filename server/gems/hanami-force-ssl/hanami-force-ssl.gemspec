# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name    = "hanami-force-ssl"
  spec.version = "0.1.0"
  spec.authors = ["eric jacobs"]
  spec.summary = "Rack-3 force-SSL middleware for Hanami 2.x — ports ActionDispatch::SSL + AssumeSSL"
  spec.files   = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 4.0"

  spec.add_dependency "rack", ">= 3"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
end
