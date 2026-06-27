# frozen_string_literal: true

require_relative "action_test_helper"
require "async"

class RunsTokenAuthTest < Minitest::Test
  include ActionTestHelper

  TOKEN = "ingest-secret-test-token-deadbeef0123456789"

  FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "claude_code_stream_text.jsonl"))

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner     = Factory[:user, github_uid: "ingest-owner", username: "ingest_owner"]
    @runs_repo = Architect::App["repos.runs_repo"]
    @settings  = Architect::App["settings"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def with_token_settings(token: TOKEN, user_id: nil)
    user_id ||= @owner.id
    @settings.stub(:ingest_token, token) do
      @settings.stub(:ingest_user_id, user_id) do
        yield
      end
    end
  end

  # --- AC2(a): valid bearer → POST /runs → 201, user_id == ingest_user_id ---

  def test_bearer_create_returns_201
    with_token_settings do
      status, headers, body = post("/runs", bearer: TOKEN)
      assert_equal 201, status
      assert_equal "application/json; charset=utf-8", headers["content-type"]
      data = parse_json(body)
      assert data.key?("id")
      assert_equal "pending", data["status"]
    end
  end

  def test_bearer_create_persists_run_owned_by_ingest_user
    with_token_settings do
      _, _, body = post("/runs", bearer: TOKEN)
      run = @runs_repo.by_pk(parse_json(body)["id"])
      refute_nil run
      assert_equal @owner.id, run.user_id, "run must be owned by ingest_user_id"
    end
  end

  # --- AC2(b): valid bearer → POST /runs/:id/ingest → 202, events > 0 ---

  def test_bearer_ingest_returns_202_with_events
    with_token_settings do
      _, _, body = post("/runs", bearer: TOKEN)
      run_id = parse_json(body)["id"]
      Sync do
        status, _, body = post_raw("/runs/#{run_id}/ingest", body: FIXTURE_JSONL, bearer: TOKEN)
        assert_equal 202, status
        data = parse_json(body)
        assert data["events"] > 0, "events must be > 0"
      end
    end
  end

  # --- AC2(c): wrong bearer → 401 on both endpoints ---

  def test_wrong_bearer_create_returns_401
    with_token_settings do
      status, _, body = post("/runs", bearer: "wrong-token")
      assert_equal 401, status
      assert parse_json(body).key?("error")
    end
  end

  def test_wrong_bearer_ingest_returns_401
    run = Factory[:run, user_id: @owner.id, status: 0]
    with_token_settings do
      status, _, body = post("/runs/#{run.id}/ingest", bearer: "wrong-token")
      assert_equal 401, status
      assert parse_json(body).key?("error")
    end
  end

  # --- AC2(d): ingest_token unset (nil) + any bearer header → 401 ---

  def test_nil_ingest_token_with_bearer_returns_401_on_create
    # No stub — settings.ingest_token is nil by default
    status, _, _ = post("/runs", bearer: TOKEN)
    assert_equal 401, status
  end

  def test_nil_ingest_token_with_bearer_returns_401_on_ingest
    run = Factory[:run, user_id: @owner.id, status: 0]
    status, _, _ = post("/runs/#{run.id}/ingest", bearer: TOKEN)
    assert_equal 401, status
  end

  # --- AC2(e): empty/blank bearer value → 401 ---

  def test_empty_bearer_returns_401_on_create
    with_token_settings do
      status, _, _ = post("/runs", bearer: "")
      assert_equal 401, status
    end
  end

  def test_empty_bearer_returns_401_on_ingest
    run = Factory[:run, user_id: @owner.id, status: 0]
    with_token_settings do
      status, _, _ = post("/runs/#{run.id}/ingest", bearer: "")
      assert_equal 401, status
    end
  end

  # --- AC3: CSRF exemption invariant — tested directly like omniauth_request_csrf_test.rb
  # calls request_validation_phase directly rather than going through the full Rack stack.
  # Hanami auto-disables CSRF before-hooks in test env, so we call verify_csrf_token? directly.

  def make_post_request(bearer: nil)
    env = Rack::MockRequest.env_for("/runs", "REQUEST_METHOD" => "POST")
    env["rack.session"] = {}
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" unless bearer.nil?
    Hanami::Action::Request.new(env: env, params: {})
  end

  def test_csrf_required_for_cookie_post
    # No bearer → verify_csrf_token? returns true (CSRF check is required for browser/cookie POSTs)
    action = Architect::Actions::Runs::Create.new
    req = make_post_request
    assert action.send(:verify_csrf_token?, req, nil),
      "cookie/session POST must have CSRF enforcement active (verify_csrf_token? must return true)"
  end

  def test_csrf_exempt_for_valid_bearer_post
    # Valid bearer → verify_csrf_token? returns false (CSRF check bypassed for machine pushes)
    with_token_settings do
      action = Architect::Actions::Runs::Create.new
      req = make_post_request(bearer: TOKEN)
      refute action.send(:verify_csrf_token?, req, nil),
        "valid bearer POST must be CSRF-exempt (verify_csrf_token? must return false)"
    end
  end

  # R5 fix: wrong bearer → CSRF exempted on PRESENCE (not validity).
  # Was assert (true) on base 06fa13d — that was the bug. Now refute (false).
  def test_csrf_not_exempt_for_wrong_bearer
    with_token_settings do
      action = Architect::Actions::Runs::Create.new
      req = make_post_request(bearer: "wrong-token")
      refute action.send(:verify_csrf_token?, req, nil),
        "wrong bearer must be CSRF-exempt for Create (bearer presence, not validity)"
    end
  end

  # --- Ingest CSRF seam tests (R5: bearer presence exempts CSRF) ---

  def test_csrf_required_for_cookie_post_ingest
    action = Architect::Actions::Runs::Ingest.new
    req = make_post_request
    assert action.send(:verify_csrf_token?, req, nil),
      "cookie/session POST to Ingest must have CSRF enforcement (verify_csrf_token? must return true)"
  end

  def test_csrf_exempt_for_valid_bearer_post_ingest
    with_token_settings do
      action = Architect::Actions::Runs::Ingest.new
      req = make_post_request(bearer: TOKEN)
      refute action.send(:verify_csrf_token?, req, nil),
        "valid bearer POST to Ingest must be CSRF-exempt (verify_csrf_token? must return false)"
    end
  end

  def test_csrf_not_exempt_for_wrong_bearer_ingest
    with_token_settings do
      action = Architect::Actions::Runs::Ingest.new
      req = make_post_request(bearer: "wrong-token")
      refute action.send(:verify_csrf_token?, req, nil),
        "wrong bearer must be CSRF-exempt for Ingest (bearer presence, not validity)"
    end
  end
end
