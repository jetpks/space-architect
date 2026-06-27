# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name    = "inertia-hanami"
  spec.version = "0.1.0"
  spec.authors = ["eric jacobs"]
  spec.summary = "Inertia.js server adapter for Hanami 2.x — faithful port of inertia_rails 3.21.1 behavior"
  spec.files   = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 4.0"

  spec.add_dependency "rack", ">= 3"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "hanami-controller", "= 2.3.2"
end
