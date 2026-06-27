# frozen_string_literal: true

# Minimal test helper for the framework-agnostic transcript PORO tests.
# Does NOT require hanami/prepare — no DB, no app boot.
$LOAD_PATH.unshift File.expand_path("../../app", __dir__)

require "minitest/autorun"
require "transcript/turn"
require "transcript/round"
require "transcript/entity"

# Adds test "description" do ... end block syntax to Minitest::Test,
# matching the style used in the Rails oracle test suite.
class Minitest::Test
  def self.test(desc, &block)
    method_name = "test_#{desc.gsub(/[^a-z0-9]+/i, "_").downcase}"
    define_method(method_name, &block)
  end
end

# Lightweight fixture message — the duck-typed interface the POROs expect:
#   #id (Integer), #role (String), #content (Array of block Hashes), #blocks (== content)
Msg = Struct.new(:id, :role, :content) do
  def blocks
    Array(content)
  end
end
