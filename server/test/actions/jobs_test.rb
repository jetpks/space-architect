# frozen_string_literal: true

require_relative "action_test_helper"

class JobsActionTest < Minitest::Test
  include ActionTestHelper

  TOKEN = "ingest-secret-test-token-deadbeef0123456789"

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:providers].delete
    OmniAuth.config.test_mode = true
    @owner         = Factory[:user, github_uid: "jobs-owner-uid", username: "jobs-owner"]
    @jobs_repo     = Space::Server::App["repos.jobs_repo"]
    @providers_repo = Space::Server::App["repos.providers_repo"]
    @settings      = Space::Server::App["settings"]
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

  # Follows a redirect to /jobs/new and returns props.errors — the house pattern from
  # conversations_test.rb's contract-failure assertions.
  def errors_after(bad_params)
    sign_in(@owner)
    status, headers, _ = post("/jobs", params: bad_params)
    assert_equal 302, status
    assert_equal "/jobs/new", headers["location"]
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/jobs/new", cookie: redirect_cookie)
    parse_json(body).dig("props", "errors")
  end

  # --- POST /jobs — AC1: browser/Inertia flow, anon --------------------------

  def test_create_anon_redirects_with_flash
    status, headers, _ = post("/jobs", params: valid_params)
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  # --- POST /jobs — AC1: browser/Inertia flow, valid spec --------------------

  def test_create_valid_spec_redirects_to_job_with_flash
    sign_in(@owner)
    status, headers, _ = post("/jobs", params: valid_params)
    assert_equal 302, status
    job = @jobs_repo.by_user(@owner.id).first
    refute_nil job
    assert_equal "/jobs/#{job.id}", headers["location"]
    assert_equal "queued", job.status
    flash = flash_from_redirect(headers)
    assert_equal "Job queued.", flash["notice"]
  end

  def test_create_persists_row_with_validated_spec
    sign_in(@owner)
    post("/jobs", params: valid_params)
    job = @jobs_repo.by_user(@owner.id).first
    refute_nil job
    assert_equal @owner.id, job.user_id
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
    post("/jobs", params: minimal)
    job = @jobs_repo.by_user(@owner.id).first
    assert_equal({}, job.spec.dig("environment", "env"))
    assert_equal [], job.spec.dig("environment", "secrets")
    assert_equal ["git"], job.spec.dig("environment", "deps")
    assert_equal({ "network" => false, "mounts" => [] }, job.spec.dig("environment", "permissions"))
  end

  # --- POST /jobs — AC1: contract failure redirects with per-field errors ----

  def test_create_missing_prompt_names_field
    errors = errors_after(valid_params.reject { |k, _| k == :prompt })
    assert errors["prompt"]
  end

  def test_create_non_http_base_url_names_field
    bad = valid_params.merge(harness: valid_params[:harness].merge(backend: { base_url: "not-a-url" }))
    errors = errors_after(bad)
    assert errors["base_url"]
  end

  def test_create_secret_ref_not_op_names_field
    bad = valid_params.merge(environment: { secrets: [{ ref: "not-op", name: "X" }] })
    errors = errors_after(bad)
    assert errors["secrets"]
  end

  def test_create_empty_debs_element_names_field
    bad = valid_params.merge(environment: { debs: ["jq", ""] })
    errors = errors_after(bad)
    assert errors["debs"]
  end

  def test_create_empty_gems_element_names_field
    bad = valid_params.merge(environment: { gems: ["rspec", ""] })
    errors = errors_after(bad)
    assert errors["gems"]
  end

  def test_create_empty_mise_element_names_field
    bad = valid_params.merge(environment: { mise: ["ruby@3.3", ""] })
    errors = errors_after(bad)
    assert errors["mise"]
  end

  def test_create_invalid_spec_does_not_persist_a_row
    sign_in(@owner)
    before = @jobs_repo.by_user(@owner.id).size
    post("/jobs", params: valid_params.reject { |k, _| k == :prompt })
    assert_equal before, @jobs_repo.by_user(@owner.id).size
  end

  # --- GET /jobs/new — providers prop (BRIEF I23 shape 1) --------------------

  def test_new_carries_empty_providers_prop_when_none_exist
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    assert_equal [], parse_json(body).dig("props", "providers")
  end

  def test_new_carries_own_providers_ordered_by_name_with_frozen_shape
    other = Factory[:user, github_uid: "jobs-new-other", username: "jobs-new-other"]
    now = Time.now
    @providers_repo.create(user_id: @owner.id, name: "zeta", base_url: "https://z.example.com",
                            api_key_ref: "op://vault/z", flavors: ["openai"], created_at: now, updated_at: now)
    @providers_repo.create(user_id: @owner.id, name: "alpha", base_url: "https://a.example.com",
                            api_key_ref: nil, flavors: [], created_at: now, updated_at: now)
    @providers_repo.create(user_id: other.id, name: "foreign", base_url: "https://f.example.com",
                            api_key_ref: nil, flavors: [], created_at: now, updated_at: now)

    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    providers = parse_json(body).dig("props", "providers")
    assert_equal %w[alpha zeta], providers.map { |p| p["name"] }
    entry = providers.first
    assert_equal %w[api_key_ref base_url flavors id name].sort, entry.keys.sort
  end

  # --- POST /jobs — AC2: Bearer form-encoded, byte-compatible ---------------

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

  # --- POST /jobs — AC2: Bearer JSON body (BodyParser registration) ---------

  def test_bearer_json_body_create_returns_201
    with_token_settings do
      status, headers, body = post_raw("/jobs", body: JSON.generate(valid_params),
                                        content_type: "application/json", bearer: TOKEN)
      assert_equal 201, status
      assert_equal "application/json; charset=utf-8", headers["content-type"]
      data = parse_json(body)
      job = @jobs_repo.by_pk(data["id"])
      assert_equal "queued", data["status"]
      assert_equal "do the thing", job.spec["prompt"]
    end
  end

  def test_bearer_json_env_non_string_value_returns_422
    with_token_settings do
      bad = valid_params.merge(environment: valid_params[:environment].merge(env: { FOO: 123 }))
      status, _, body = post_raw("/jobs", body: JSON.generate(bad),
                                  content_type: "application/json", bearer: TOKEN)
      assert_equal 422, status
      errors = parse_json(body)["errors"]
      assert errors.dig("environment", "env", "FOO")
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
