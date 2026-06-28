# frozen_string_literal: true

require_relative "support"

class StreamKeyTest < Minitest::Test
  def test_for_integer_id
    assert_equal "run:42", Space::Server::Runs::StreamKey.for(42)
  end

  def test_for_string_id
    assert_equal "run:abc", Space::Server::Runs::StreamKey.for("abc")
  end

  def test_ttl_seconds
    assert_equal 1800, Space::Server::Runs::StreamKey::TTL_SECONDS
  end

  def test_for_zero
    assert_equal "run:0", Space::Server::Runs::StreamKey.for(0)
  end
end
