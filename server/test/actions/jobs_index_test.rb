# frozen_string_literal: true

require_relative "action_test_helper"

class JobsIndexTest < Minitest::Test
  include ActionTestHelper

  TOKEN = "jobs-index-test-token-deadbeef0123456789"

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner    = Factory[:user, github_uid: "jobs-index-owner", username: "jobs-index-owner"]
    @other    = Factory[:user, github_uid: "jobs-index-other", username: "jobs-index-other"]
    @settings = Space::Server::App["settings"]
  end

  def with_token_settings(token: TOKEN, user_id:)
    @settings.stub(:ingest_token, token) do
      @settings.stub(:ingest_user_id, user_id) do
        yield
      end
    end
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

  # --- Bearer personality (AC2) -------------------------------------------

  def test_index_bearer_wrong_token_returns_401
    with_token_settings(user_id: @owner.id) do
      env = Rack::MockRequest.env_for("/jobs", "REQUEST_METHOD" => "GET")
      env["HTTP_AUTHORIZATION"] = "Bearer wrong-token"
      status, _, body = app.call(env)
      assert_equal 401, status
      assert parse_json(body).key?("error")
    end
  end

  def test_index_bearer_returns_json_jobs_owner_scoped_newest_first
    older = Factory[:job, user_id: @owner.id, created_at: Time.now - 60, updated_at: Time.now - 60]
    newer = Factory[:job, user_id: @owner.id]
    Factory[:job, user_id: @other.id]

    with_token_settings(user_id: @owner.id) do
      env = Rack::MockRequest.env_for("/jobs", "REQUEST_METHOD" => "GET")
      env["HTTP_AUTHORIZATION"] = "Bearer #{TOKEN}"
      status, headers, body = app.call(env)
      assert_equal 200, status
      assert_equal "application/json; charset=utf-8", headers["content-type"]
      jobs = parse_json(body)["jobs"]
      assert_equal [newer.id, older.id], jobs.map { |j| j["id"] }
    end
  end

  # --- provenance (I16) -------------------------------------------------

  def test_index_job_shape_omits_provenance_when_absent
    Factory[:job, user_id: @owner.id]
    sign_in(@owner)
    _, _, body = inertia_get("/jobs")
    entry = parse_json(body).dig("props", "jobs").first
    refute entry.key?("provenance")
  end

  def test_index_job_shape_includes_provenance_when_present
    spec = {
      "harness" => { "type" => "claude", "model" => "sonnet", "backend" => { "base_url" => "https://api.example.com" } },
      "prompt" => "do the thing",
      "environment" => { "env" => {}, "secrets" => [], "deps" => [], "permissions" => { "network" => false, "mounts" => [] } },
      "provenance" => { "space" => "s1", "iteration" => "I16", "lane" => "server" }
    }
    job = Factory[:job, user_id: @owner.id, spec: spec]
    sign_in(@owner)
    _, _, body = inertia_get("/jobs")
    entry = parse_json(body).dig("props", "jobs").find { |j| j["id"] == job.id }
    assert_equal({ "space" => "s1", "iteration" => "I16", "lane" => "server" }, entry["provenance"])
  end

  def test_index_bearer_job_shape
    job = Factory[:job, user_id: @owner.id]
    with_token_settings(user_id: @owner.id) do
      env = Rack::MockRequest.env_for("/jobs", "REQUEST_METHOD" => "GET")
      env["HTTP_AUTHORIZATION"] = "Bearer #{TOKEN}"
      _, _, body = app.call(env)
      entry = parse_json(body)["jobs"].first
      assert_equal job.id, entry["id"]
      assert_equal "queued", entry["status"]
      refute_nil entry["created_at"]
      assert entry.key?("run_id")
    end
  end
end
