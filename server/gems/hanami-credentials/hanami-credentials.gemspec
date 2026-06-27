# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name    = "hanami-credentials"
  spec.version = "0.1.0"
  spec.authors = ["eric jacobs"]
  spec.summary = "AES-256-GCM encrypted settings store for Hanami 2.x"
  spec.files   = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 4.0"

  # Ruby 4.0: openssl and base64 are no longer default gems — declare explicitly.
  spec.add_dependency "openssl"
  spec.add_dependency "base64"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
end
