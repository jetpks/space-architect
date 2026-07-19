# frozen_string_literal: true

require_relative "action_test_helper"

class JobsNewTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
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
end
