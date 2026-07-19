# frozen_string_literal: true

require_relative "action_test_helper"

class JobsIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "jobs-index-owner", username: "jobs-index-owner"]
    @other = Factory[:user, github_uid: "jobs-index-other", username: "jobs-index-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_index_anon_redirects_with_flash
    status, headers, _ = get("/jobs")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_index_lists_own_jobs_only_newest_first
    older = Factory[:job, user_id: @owner.id, created_at: Time.now - 60, updated_at: Time.now - 60]
    newer = Factory[:job, user_id: @owner.id]
    Factory[:job, user_id: @other.id]

    sign_in(@owner)
    status, _, body = inertia_get("/jobs")
    assert_equal 200, status
    jobs = parse_json(body).dig("props", "jobs")
    assert_equal [newer.id, older.id], jobs.map { |j| j["id"] }
  end

  def test_index_job_shape
    job = Factory[:job, user_id: @owner.id]
    sign_in(@owner)
    _, _, body = inertia_get("/jobs")
    entry = parse_json(body).dig("props", "jobs").first
    assert_equal job.id, entry["id"]
    assert_equal "queued", entry["status"]
    assert_equal "sonnet", entry["model"]
    assert entry.key?("created_at")
    assert_nil entry["run_id"]
  end
end
