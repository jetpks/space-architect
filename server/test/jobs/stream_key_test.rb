# frozen_string_literal: true

require_relative "../test_helper"
require "space/server/jobs/stream_key"

class JobsStreamKeyTest < Minitest::Test
  def test_for_integer_id
    assert_equal "job:42:raw", Space::Server::Jobs::StreamKey.for(42)
  end

  def test_for_string_id
    assert_equal "job:abc:raw", Space::Server::Jobs::StreamKey.for("abc")
  end

  def test_ttl_seconds
    assert_equal 1800, Space::Server::Jobs::StreamKey::TTL_SECONDS
  end
end
