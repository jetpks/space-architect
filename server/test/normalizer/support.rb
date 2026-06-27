# frozen_string_literal: true

# Minimal bootstrap for normalizer unit tests — does NOT boot Hanami.
# Mirrors the pattern in test/transcript/support.rb.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)

require "json"
require "architect/normalizer"
require "minitest/autorun"

class Minitest::Test
  def self.test(desc, &block)
    method_name = "test_#{desc.gsub(/[^a-z0-9]+/i, "_").downcase}"
    define_method(method_name, &block)
  end
end

NORMALIZER_FIXTURE_DIR = File.expand_path("../fixtures/files", __dir__)
