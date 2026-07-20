# frozen_string_literal: true

require_relative "action_test_helper"

class ProfilesDestroyTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:profiles].delete
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "profiles-destroy-owner", username: "profiles-destroy-owner"]
    @other = Factory[:user, github_uid: "profiles-destroy-other", username: "profiles-destroy-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def profiles_repo = Space::Server::Repos::ProfilesRepo.new

  def test_destroy_anon_redirects_with_flash
    profile = Factory[:profile, user_id: @owner.id]
    status, headers, _ = post("/profiles/#{profile.id}/delete")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
    refute_nil profiles_repo.by_pk(profile.id)
  end

  def test_destroy_own_profile_succeeds_and_flashes
    profile = Factory[:profile, user_id: @owner.id]
    sign_in(@owner)
    status, headers, _ = post("/profiles/#{profile.id}/delete")
    assert_equal 302, status
    assert_equal "/profiles", headers["location"]
    assert_nil profiles_repo.by_pk(profile.id)
    flash = flash_from_redirect(headers, cookie: headers["set-cookie"]&.split(";")&.first)
    assert_equal "Profile deleted.", flash["notice"]
  end

  def test_destroy_foreign_profile_returns_404
    profile = Factory[:profile, user_id: @other.id]
    sign_in(@owner)
    status, _, body = post("/profiles/#{profile.id}/delete")
    assert_equal 404, status
    assert parse_json(body).key?("error")
    refute_nil profiles_repo.by_pk(profile.id)
  end

  def test_destroy_unknown_id_returns_404
    sign_in(@owner)
    status, = post("/profiles/999999/delete")
    assert_equal 404, status
  end
end
