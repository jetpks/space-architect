# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/contracts/update_share"

class UpdateShareContractTest < Minitest::Test
  def contract = Architect::Contracts::UpdateShare.new

  def test_valid_access_view
    r = contract.call(share: {access: "view"})
    assert r.success?
  end

  def test_valid_access_note
    r = contract.call(share: {access: "note"})
    assert r.success?
  end

  def test_rejects_missing_access
    r = contract.call(share: {})
    assert r.failure?
    assert_includes r.errors.to_h.dig(:share, :access), "is missing"
  end

  def test_rejects_empty_access
    r = contract.call(share: {access: ""})
    assert r.failure?
    assert_includes r.errors.to_h.dig(:share, :access), "must be filled"
  end

  def test_rejects_missing_outer_share_key
    r = contract.call({})
    assert r.failure?
    assert_includes r.errors.to_h[:share], "is missing"
  end

  def test_rejects_wrong_type_for_share
    r = contract.call(share: "bad")
    assert r.failure?
    assert_includes r.errors.to_h[:share], "must be a hash"
  end

  def test_unknown_keys_dropped
    r = contract.call(share: {access: "view", evil: "x"})
    assert r.success?
    refute r.to_h.dig(:share, :evil)
  end
end
