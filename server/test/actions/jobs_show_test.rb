# frozen_string_literal: true

require_relative "action_test_helper"

class JobsShowTest < Minitest::Test
  include ActionTestHelper

  TOKEN = "jobs-show-test-token-deadbeef0123456789"

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "jobs-show-owner", username: "jobs-show-owner"]
    @other = Factory[:user, github_uid: "jobs-show-other", username: "jobs-show-other"]
    @settings = Space::Server::App["settings"]
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

  def test_show_returns_404_for_missing_job
    sign_in(@owner)
    status, _, _ = get("/jobs/99999")
    assert_equal 404, status
  end

  # --- browser/Inertia personality (AC3) -------------------------------------

  def test_show_anon_redirects_with_flash
    job = Factory[:job, user_id: @owner.id]
    status, headers, _ = get("/jobs/#{job.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_show_non_owner_redirects_with_flash
    job = Factory[:job, user_id: @owner.id]
    sign_in(@other)
    status, headers, _ = get("/jobs/#{job.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Not authorized.", flash["alert"]
  end

  def test_show_owner_renders_inertia_with_job_props
    job = Factory[:job, user_id: @owner.id, run_id: nil]
    sign_in(@owner)
    status, headers, body = inertia_get("/jobs/#{job.id}")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    page = parse_json(body)
    assert_equal "Jobs/Show", page["component"]
    props = page.dig("props", "job")
    assert_equal job.id, props["id"]
    assert_equal "queued", props["status"]
    assert_equal 0, props["attempts"]
    assert_nil props["run_id"]
    assert_kind_of Hash, props["spec"]
    assert props.key?("created_at")
    assert props.key?("updated_at")
  end

  # --- Bearer personality — unchanged JSON shape and authz (AC2/AC3) --------
  # A request with no Authorization header at all is indistinguishable from an
  # anonymous browser visit — see test_show_anon_redirects_with_flash above —
  # so "Bearer, no/wrong token" is only meaningful once the header is present.

  def test_show_bearer_wrong_token_returns_401
    job = Factory[:job, user_id: @owner.id]
    with_token_settings(user_id: @owner.id) do
      env = Rack::MockRequest.env_for("/jobs/#{job.id}", "REQUEST_METHOD" => "GET")
      env["HTTP_AUTHORIZATION"] = "Bearer wrong-token"
      status, _, body = app.call(env)
      assert_equal 401, status
      assert parse_json(body).key?("error")
    end
  end

  def test_show_bearer_non_owner_returns_403
    job = Factory[:job, user_id: @owner.id]
    with_token_settings(user_id: @other.id) do
      env = Rack::MockRequest.env_for("/jobs/#{job.id}", "REQUEST_METHOD" => "GET")
      env["HTTP_AUTHORIZATION"] = "Bearer #{TOKEN}"
      status, _, body = app.call(env)
      assert_equal 403, status
      assert parse_json(body).key?("error")
    end
  end

  # --- provenance (I16) -------------------------------------------------
  # Show already renders the full spec column — provenance rides along once
  # the contract accepts it, no action-layer change needed.

  def test_show_owner_inertia_props_include_provenance_when_present
    spec = {
      "harness" => { "type" => "claude", "model" => "sonnet", "backend" => { "base_url" => "https://api.example.com" } },
      "prompt" => "do the thing",
      "environment" => {},
      "provenance" => { "space" => "s1", "iteration" => "I16", "lane" => "server" }
    }
    job = Factory[:job, user_id: @owner.id, run_id: nil, spec: spec]
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/#{job.id}")
    props = parse_json(body).dig("props", "job")
    assert_equal({ "space" => "s1", "iteration" => "I16", "lane" => "server" }, props.dig("spec", "provenance"))
  end

  def test_show_bearer_owner_returns_200_with_job_json
    job = Factory[:job, user_id: @owner.id]
    with_token_settings(user_id: @owner.id) do
      env = Rack::MockRequest.env_for("/jobs/#{job.id}", "REQUEST_METHOD" => "GET")
      env["HTTP_AUTHORIZATION"] = "Bearer #{TOKEN}"
      status, headers, body = app.call(env)
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
end
