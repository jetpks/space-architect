# frozen_string_literal: true

require_relative "action_test_helper"

class JobsActionTest < Minitest::Test
  include ActionTestHelper

  TOKEN = "ingest-secret-test-token-deadbeef0123456789"

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner     = Factory[:user, github_uid: "jobs-owner-uid", username: "jobs-owner"]
    @jobs_repo = Space::Server::App["repos.jobs_repo"]
    @settings  = Space::Server::App["settings"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def valid_params
    {
      harness: {
        type: "claude", model: "claude-sonnet-5",
        backend: { base_url: "https://api.example.com/v1", api_key_ref: "op://vault/item" },
        args: ["--flag"]
      },
      prompt: "do the thing",
      environment: {
        env: { FOO: "bar" },
        secrets: [{ ref: "op://vault/item2", name: "API_KEY" }],
        deps: ["git"],
        permissions: { network: "true", mounts: ["/tmp"] }
      }
    }
  end

  # --- POST /jobs — AC1/AC3: auth -------------------------------------------

  def test_create_anon_returns_401
    status, _, body = post("/jobs", params: valid_params)
    assert_equal 401, status
    assert parse_json(body).key?("error")
  end

  # --- POST /jobs — AC1: valid spec -> 201 + persisted row -----------------

  def test_create_valid_spec_returns_201_queued
    sign_in(@owner)
    status, headers, body = post("/jobs", params: valid_params)
    assert_equal 201, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)
    assert data.key?("id")
    assert_equal "queued", data["status"]
  end

  def test_create_persists_row_with_validated_spec
    sign_in(@owner)
    _, _, body = post("/jobs", params: valid_params)
    job = @jobs_repo.by_pk(parse_json(body)["id"])
    refute_nil job
    assert_equal @owner.id, job.user_id
    assert_equal "queued", job.status
    assert_equal "claude",  job.spec.dig("harness", "type")
    assert_equal "do the thing", job.spec["prompt"]
    assert_equal ["op://vault/item2"], job.spec.dig("environment", "secrets").map { |s| s["ref"] }
    assert_equal true, job.spec.dig("environment", "permissions", "network")
  end

  def test_create_minimal_spec_applies_defaults
    sign_in(@owner)
    # www-form-urlencoded can't carry a bare empty `environment: {}` (no leaf
    # pairs to encode) — send one real leaf field so the key round-trips, and
    # confirm the untouched sub-fields (env/secrets/deps/permissions) default.
    minimal = {
      harness: { type: "claude", model: "sonnet", backend: { base_url: "https://api.example.com" } },
      prompt: "hi",
      environment: { deps: ["git"] }
    }
    _, _, body = post("/jobs", params: minimal)
    job = @jobs_repo.by_pk(parse_json(body)["id"])
    assert_equal({}, job.spec.dig("environment", "env"))
    assert_equal [], job.spec.dig("environment", "secrets")
    assert_equal ["git"], job.spec.dig("environment", "deps")
    assert_equal({ "network" => false, "mounts" => [] }, job.spec.dig("environment", "permissions"))
  end

  # --- POST /jobs — AC2: invalid spec -> 422 --------------------------------

  def test_create_missing_prompt_returns_422
    sign_in(@owner)
    bad = valid_params.reject { |k, _| k == :prompt }
    status, _, body = post("/jobs", params: bad)
    assert_equal 422, status
    errors = parse_json(body)["errors"]
    assert errors["prompt"]
  end

  def test_create_unknown_harness_type_returns_422
    sign_in(@owner)
    bad = valid_params.merge(harness: valid_params[:harness].merge(type: "gpt4"))
    status, _, body = post("/jobs", params: bad)
    assert_equal 422, status
    errors = parse_json(body)["errors"]
    assert errors.dig("harness", "type")
  end

  def test_create_non_http_base_url_returns_422
    sign_in(@owner)
    bad = valid_params.merge(harness: valid_params[:harness].merge(backend: { base_url: "not-a-url" }))
    status, _, body = post("/jobs", params: bad)
    assert_equal 422, status
    errors = parse_json(body)["errors"]
    assert errors.dig("harness", "backend", "base_url")
  end

  def test_create_secret_ref_not_op_returns_422
    sign_in(@owner)
    bad = valid_params.merge(environment: { secrets: [{ ref: "not-op", name: "X" }] })
    status, _, body = post("/jobs", params: bad)
    assert_equal 422, status
    errors = parse_json(body)["errors"]
    assert errors.dig("environment", "secrets")
  end

  def test_create_invalid_spec_does_not_persist_a_row
    sign_in(@owner)
    before = @jobs_repo.by_user(@owner.id).size
    post("/jobs", params: valid_params.reject { |k, _| k == :prompt })
    assert_equal before, @jobs_repo.by_user(@owner.id).size
  end

  # --- POST /jobs — AC3: ingest-token bearer bypasses CSRF ------------------

  def with_token_settings(token: TOKEN, user_id: nil)
    user_id ||= @owner.id
    @settings.stub(:ingest_token, token) do
      @settings.stub(:ingest_user_id, user_id) do
        yield
      end
    end
  end

  def test_bearer_create_returns_201_owned_by_ingest_user
    with_token_settings do
      status, _, body = post("/jobs", params: valid_params, bearer: TOKEN)
      assert_equal 201, status
      job = @jobs_repo.by_pk(parse_json(body)["id"])
      assert_equal @owner.id, job.user_id
    end
  end

  def test_wrong_bearer_create_returns_401
    with_token_settings do
      status, _, _ = post("/jobs", params: valid_params, bearer: "wrong-token")
      assert_equal 401, status
    end
  end

  def make_post_request(bearer: nil)
    env = Rack::MockRequest.env_for("/jobs", "REQUEST_METHOD" => "POST")
    env["rack.session"] = {}
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" unless bearer.nil?
    Hanami::Action::Request.new(env: env, params: {})
  end

  def test_csrf_required_for_cookie_post
    action = Space::Server::Actions::Jobs::Create.new
    req = make_post_request
    assert action.send(:verify_csrf_token?, req, nil),
      "cookie/session POST must have CSRF enforcement active"
  end

  def test_csrf_exempt_for_valid_bearer_post
    with_token_settings do
      action = Space::Server::Actions::Jobs::Create.new
      req = make_post_request(bearer: TOKEN)
      refute action.send(:verify_csrf_token?, req, nil),
        "valid bearer POST must be CSRF-exempt"
    end
  end
end
