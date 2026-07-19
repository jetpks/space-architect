# frozen_string_literal: true

require_relative "action_test_helper"

class JobsCancelTest < Minitest::Test
  include ActionTestHelper

  TOKEN = "jobs-cancel-test-token-deadbeef0123456789"

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner     = Factory[:user, github_uid: "jobs-cancel-owner", username: "jobs-cancel-owner"]
    @other     = Factory[:user, github_uid: "jobs-cancel-other", username: "jobs-cancel-other"]
    @jobs_repo = Space::Server::App["repos.jobs_repo"]
    @settings  = Space::Server::App["settings"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def with_token_settings(token: TOKEN, user_id:)
    @settings.stub(:ingest_token, token) do
      @settings.stub(:ingest_user_id, user_id) do
        yield
      end
    end
  end

  def test_cancel_missing_job_returns_404
    sign_in(@owner)
    status, _, _ = post("/jobs/99999/cancel")
    assert_equal 404, status
  end

  # --- browser/Inertia personality --------------------------------------

  def test_cancel_anon_redirects_with_flash
    job = Factory[:job, user_id: @owner.id]
    status, headers, _ = post("/jobs/#{job.id}/cancel")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_cancel_non_owner_redirects_with_flash
    job = Factory[:job, user_id: @owner.id]
    sign_in(@other)
    status, headers, _ = post("/jobs/#{job.id}/cancel")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Not authorized.", flash["alert"]
    assert_equal "queued", @jobs_repo.by_pk(job.id).status
  end

  def test_cancel_queued_job_redirects_back_with_notice_and_cancels
    job = Factory[:job, user_id: @owner.id]
    sign_in(@owner)
    status, headers, _ = post("/jobs/#{job.id}/cancel")
    assert_equal 302, status
    flash = flash_from_redirect(headers)
    assert_equal "Job canceled.", flash["notice"]
    assert_equal "canceled", @jobs_repo.by_pk(job.id).status
  end

  def test_cancel_terminal_job_redirects_back_with_alert_and_does_not_change_status
    job = Factory[:job, user_id: @owner.id, status: "succeeded"]
    sign_in(@owner)
    status, headers, _ = post("/jobs/#{job.id}/cancel")
    assert_equal 302, status
    flash = flash_from_redirect(headers)
    assert_equal "Job already succeeded.", flash["alert"]
    assert_equal "succeeded", @jobs_repo.by_pk(job.id).status
  end

  # --- Bearer personality -------------------------------------------------

  def test_cancel_bearer_wrong_token_returns_401
    job = Factory[:job, user_id: @owner.id]
    with_token_settings(user_id: @owner.id) do
      status, _, body = post("/jobs/#{job.id}/cancel", bearer: "wrong-token")
      assert_equal 401, status
      assert parse_json(body).key?("error")
      assert_equal "queued", @jobs_repo.by_pk(job.id).status
    end
  end

  def test_cancel_bearer_non_owner_returns_403
    job = Factory[:job, user_id: @owner.id]
    with_token_settings(user_id: @other.id) do
      status, _, body = post("/jobs/#{job.id}/cancel", bearer: TOKEN)
      assert_equal 403, status
      assert parse_json(body).key?("error")
      assert_equal "queued", @jobs_repo.by_pk(job.id).status
    end
  end

  def test_cancel_bearer_queued_job_returns_200_canceled
    job = Factory[:job, user_id: @owner.id]
    with_token_settings(user_id: @owner.id) do
      status, headers, body = post("/jobs/#{job.id}/cancel", bearer: TOKEN)
      assert_equal 200, status
      assert_equal "application/json; charset=utf-8", headers["content-type"]
      data = parse_json(body)
      assert_equal job.id, data["id"]
      assert_equal "canceled", data["status"]
      assert_equal "canceled", @jobs_repo.by_pk(job.id).status
    end
  end

  def test_cancel_bearer_running_job_returns_200_canceled
    job = Factory[:job, user_id: @owner.id, status: "running", leased_until: Time.now + 60]
    with_token_settings(user_id: @owner.id) do
      status, _, body = post("/jobs/#{job.id}/cancel", bearer: TOKEN)
      assert_equal 200, status
      assert_equal "canceled", parse_json(body)["status"]
      canceled = @jobs_repo.by_pk(job.id)
      assert_equal "canceled", canceled.status
      assert_nil canceled.leased_until
    end
  end

  def test_cancel_bearer_terminal_job_returns_409_naming_status
    job = Factory[:job, user_id: @owner.id, status: "failed"]
    with_token_settings(user_id: @owner.id) do
      status, _, body = post("/jobs/#{job.id}/cancel", bearer: TOKEN)
      assert_equal 409, status
      assert_equal "Job already failed.", parse_json(body)["error"]
      assert_equal "failed", @jobs_repo.by_pk(job.id).status
    end
  end

  def test_cancel_bearer_already_canceled_job_returns_409
    job = Factory[:job, user_id: @owner.id, status: "canceled"]
    with_token_settings(user_id: @owner.id) do
      status, _, body = post("/jobs/#{job.id}/cancel", bearer: TOKEN)
      assert_equal 409, status
      assert_equal "Job already canceled.", parse_json(body)["error"]
    end
  end

  # --- CSRF exemption invariant (create/show precedent) -------------------

  def make_post_request(bearer: nil)
    env = Rack::MockRequest.env_for("/jobs/1/cancel", "REQUEST_METHOD" => "POST")
    env["rack.session"] = {}
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" unless bearer.nil?
    Hanami::Action::Request.new(env: env, params: {})
  end

  def test_csrf_required_for_cookie_post
    action = Space::Server::Actions::Jobs::Cancel.new
    req = make_post_request
    assert action.send(:verify_csrf_token?, req, nil),
      "cookie/session POST must have CSRF enforcement active"
  end

  def test_csrf_exempt_for_valid_bearer_post
    with_token_settings(user_id: @owner.id) do
      action = Space::Server::Actions::Jobs::Cancel.new
      req = make_post_request(bearer: TOKEN)
      refute action.send(:verify_csrf_token?, req, nil),
        "valid bearer POST must be CSRF-exempt"
    end
  end
end
