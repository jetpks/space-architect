# frozen_string_literal: true

require_relative "action_test_helper"

class ProfilesIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:profiles].delete
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "profiles-index-owner", username: "profiles-index-owner"]
    @other = Factory[:user, github_uid: "profiles-index-other", username: "profiles-index-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_index_anon_redirects_with_flash
    status, headers, _ = get("/profiles")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_index_lists_own_profiles_only_ordered_by_name
    Factory[:profile, user_id: @owner.id, name: "zeta"]
    Factory[:profile, user_id: @owner.id, name: "alpha"]
    Factory[:profile, user_id: @other.id, name: "foreign"]

    sign_in(@owner)
    status, _, body = inertia_get("/profiles")
    assert_equal 200, status
    names = parse_json(body).dig("props", "profiles").map { |p| p["name"] }
    assert_equal %w[alpha zeta], names
  end

  def test_index_profile_shape
    profile = Factory[:profile, user_id: @owner.id]
    sign_in(@owner)
    _, _, body = inertia_get("/profiles")
    entry = parse_json(body).dig("props", "profiles").first
    assert_equal profile.id, entry["id"]
    assert_equal profile.name, entry["name"]
    assert_equal "claude", entry["harness_type"]
    assert entry.key?("spec")
  end
end
