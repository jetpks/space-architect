# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/contracts/create_share"

class CreateShareContractTest < Minitest::Test
  def contract = Space::Server::Contracts::CreateShare.new

  def test_valid_with_login_and_access
    r = contract.call(share: {login: "jetpks", access: "view"})
    assert r.success?
  end

  def test_valid_with_login_only_access_optional
    r = contract.call(share: {login: "jetpks"})
    assert r.success?
    assert_nil r.to_h.dig(:share, :access)
  end

  def test_rejects_missing_login
    r = contract.call(share: {access: "view"})
    assert r.failure?
    assert r.errors.to_h.dig(:share, :login)
  end

  def test_rejects_empty_login
    r = contract.call(share: {login: ""})
    assert r.failure?
    assert_includes r.errors.to_h.dig(:share, :login), "must be filled"
  end

  def test_rejects_missing_outer_share_key
    r = contract.call({})
    assert r.failure?
    assert_includes r.errors.to_h[:share], "is missing"
  end

  def test_rejects_share_as_string
    r = contract.call(share: "bad")
    assert r.failure?
    assert_includes r.errors.to_h[:share], "must be a hash"
  end

  def test_unknown_keys_are_dropped
    r = contract.call(share: {login: "user", access: "view", evil: "x"})
    assert r.success?
    refute r.to_h.dig(:share, :evil)
  end

  def test_valid_note_access
    r = contract.call(share: {login: "org_name", access: "note"})
    assert r.success?
  end
end
