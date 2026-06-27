# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name    = "hanami-healthcheck"
  spec.version = "0.1.0"
  spec.authors = ["eric jacobs"]
  spec.summary = "Mountable Rack healthcheck endpoint for Hanami 2.x"
  spec.files   = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 4.0"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rack"
end
