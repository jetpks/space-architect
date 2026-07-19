# frozen_string_literal: true

require_relative "action_test_helper"

class JobsShowTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "jobs-show-owner", username: "jobs-show-owner"]
    @other = Factory[:user, github_uid: "jobs-show-other", username: "jobs-show-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_show_returns_404_for_missing_job
    sign_in(@owner)
    status, _, _ = get("/jobs/99999")
    assert_equal 404, status
  end

  def test_show_anon_returns_401
    job = Factory[:job, user_id: @owner.id]
    status, _, body = get("/jobs/#{job.id}")
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  def test_show_non_owner_returns_403
    job = Factory[:job, user_id: @owner.id]
    sign_in(@other)
    status, _, body = get("/jobs/#{job.id}")
    assert_equal 403, status
    assert parse_json(body).key?("error")
  end

  def test_show_owner_returns_200_with_job_json
    job = Factory[:job, user_id: @owner.id]
    sign_in(@owner)
    status, headers, body = get("/jobs/#{job.id}")
    assert_equal 200, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)
    assert_equal job.id, data["id"]
    assert_equal "queued", data["status"]
    assert_kind_of Hash, data["spec"]
    assert data.key?("run_id")
    assert data.key?("created_at")
    assert data.key?("updated_at")
  end
end
