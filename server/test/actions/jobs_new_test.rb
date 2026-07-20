# frozen_string_literal: true

require_relative "action_test_helper"

class JobsNewTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:profiles].delete
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "jobs-new-owner", username: "jobs-new-owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_new_anon_redirects_with_flash
    status, headers, _ = get("/jobs/new")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_new_renders_inertia_page
    sign_in(@owner)
    status, headers, body = inertia_get("/jobs/new")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    assert_equal "Jobs/New", parse_json(body)["component"]
  end

  def test_new_carries_empty_profiles_prop_when_none_exist
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    assert_equal [], parse_json(body).dig("props", "profiles")
  end

  def test_new_carries_own_profiles_ordered_by_name
    other = Factory[:user, github_uid: "jobs-new-other", username: "jobs-new-other"]
    Factory[:profile, user_id: @owner.id, name: "zeta"]
    Factory[:profile, user_id: @owner.id, name: "alpha"]
    Factory[:profile, user_id: other.id, name: "foreign"]

    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    profiles = parse_json(body).dig("props", "profiles")
    assert_equal %w[alpha zeta], profiles.map { |p| p["name"] }
  end

  def test_new_profile_shape
    profile = Factory[:profile, user_id: @owner.id]
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    entry = parse_json(body).dig("props", "profiles").first
    assert_equal profile.id, entry["id"]
    assert_equal profile.name, entry["name"]
    assert_equal "claude", entry["harness_type"]
    assert entry.key?("spec")
  end
end
