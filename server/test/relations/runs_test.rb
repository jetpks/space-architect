# frozen_string_literal: true

require_relative "../test_helper"

# Pins the runs status wire contract (I46): 4 => :canceled joins the
# existing pending/live/complete/failed integers.
class RunsRelationTest < Minitest::Test
  STATUS_MAP = Space::Server::Relations::Runs::STATUS_MAP

  def test_status_map_includes_canceled
    assert_equal({ 0 => :pending, 1 => :live, 2 => :complete, 3 => :failed, 4 => :canceled }, STATUS_MAP)
  end

  def test_status_to_int_inverts_canceled
    assert_equal 4, Space::Server::Relations::Runs::STATUS_TO_INT[:canceled]
  end

  def test_status_read_coerces_4_to_canceled
    assert_equal :canceled, Space::Server::Relations::Runs::STATUS_READ[4]
  end
end
