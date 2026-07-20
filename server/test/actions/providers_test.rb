# frozen_string_literal: true

require_relative "action_test_helper"
require_relative "../../app/actions/providers/models"
require_relative "../../app/actions/providers/pi_extension"

class ProvidersTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:providers].delete
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "providers-owner", username: "providers-owner"]
    @other = Factory[:user, github_uid: "providers-other", username: "providers-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def providers_repo = Space::Server::Repos::ProvidersRepo.new

  def make_provider(user, attrs = {})
    now = Time.now
    providers_repo.create({
      user_id: user.id, name: "gateway", base_url: "https://api.example.com/v1",
      api_key_ref: "op://vault/item", flavors: ["openai"], created_at: now, updated_at: now
    }.merge(attrs))
  end

  def valid_params
    { name: "my-gateway", base_url: "https://api.example.com/v1", api_key_ref: "op://vault/item",
      flavors: ["openai", "anthropic"] }
  end

  # --- Index ----------------------------------------------------------------

  def test_index_anon_redirects_with_flash
    status, headers, _ = get("/providers")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_index_lists_only_own_providers
    make_provider(@owner, name: "mine")
    make_provider(@other, name: "theirs")
    sign_in(@owner)
    _, _, body = inertia_get("/providers")
    providers = parse_json(body).dig("props", "providers")
    assert_equal ["mine"], providers.map { |p| p["name"] }
  end

  # --- New --------------------------------------------------------------------

  def test_new_anon_redirects_with_flash
    status, headers, _ = get("/providers/new")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  # --- Create -----------------------------------------------------------------

  def test_create_anon_redirects_with_flash
    status, headers, _ = post("/providers", params: valid_params)
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_create_valid_params_persists_row_and_redirects_with_flash
    sign_in(@owner)
    status, headers, _ = post("/providers", params: valid_params)
    assert_equal 302, status
    assert_equal "/providers", headers["location"]

    provider = providers_repo.list_for_user(@owner.id).first
    refute_nil provider
    assert_equal @owner.id, provider.user_id
    assert_equal "my-gateway", provider.name
    assert_equal "https://api.example.com/v1", provider.base_url
    assert_equal "op://vault/item", provider.api_key_ref
    assert_equal ["openai", "anthropic"], provider.flavors

    flash = flash_from_redirect(headers, cookie: headers["set-cookie"]&.split(";")&.first)
    assert_equal "Provider created.", flash["notice"]
  end

  def test_create_without_api_key_ref_persists_nil
    sign_in(@owner)
    post("/providers", params: valid_params.reject { |k, _| k == :api_key_ref })
    provider = providers_repo.list_for_user(@owner.id).first
    refute_nil provider
    assert_nil provider.api_key_ref
  end

  def test_create_missing_name_names_field_without_exception
    sign_in(@owner)
    status, headers, _ = post("/providers", params: valid_params.reject { |k, _| k == :name })
    assert_equal 302, status
    assert_equal "/providers/new", headers["location"]
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/providers/new", cookie: redirect_cookie)
    errors = parse_json(body).dig("props", "errors")
    assert errors["name"]
    assert_equal 0, providers_repo.list_for_user(@owner.id).size
  end

  def test_create_non_http_base_url_names_field
    sign_in(@owner)
    status, headers, _ = post("/providers", params: valid_params.merge(base_url: "not-a-url"))
    assert_equal "/providers/new", headers["location"]
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/providers/new", cookie: redirect_cookie)
    errors = parse_json(body).dig("props", "errors")
    assert errors["base_url"]
  end

  def test_create_raw_key_api_key_ref_names_field
    sign_in(@owner)
    status, headers, _ = post("/providers", params: valid_params.merge(api_key_ref: "sk-abc123"))
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/providers/new", cookie: redirect_cookie)
    errors = parse_json(body).dig("props", "errors")
    assert errors["api_key_ref"]
  end

  def test_create_unknown_flavor_names_field
    sign_in(@owner)
    _, headers, _ = post("/providers", params: valid_params.merge(flavors: ["bogus"]))
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/providers/new", cookie: redirect_cookie)
    errors = parse_json(body).dig("props", "errors")
    assert errors["flavors"]
  end

  def test_create_malformed_payload_names_no_field_without_exception
    sign_in(@owner)
    status, headers, _ = post("/providers", params: { name: "x" })
    assert_equal 302, status
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/providers/new", cookie: redirect_cookie)
    errors = parse_json(body).dig("props", "errors")
    assert errors["flavors"]
    assert_equal 0, providers_repo.list_for_user(@owner.id).size
  end

  # --- Destroy ------------------------------------------------------------

  def test_destroy_anon_redirects_with_flash
    provider = make_provider(@owner)
    status, headers, _ = post("/providers/#{provider.id}/delete")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    refute_nil providers_repo.by_id_for_user(provider.id, @owner.id)
  end

  def test_destroy_own_provider_succeeds_and_flashes
    provider = make_provider(@owner)
    sign_in(@owner)
    status, headers, _ = post("/providers/#{provider.id}/delete")
    assert_equal 302, status
    assert_equal "/providers", headers["location"]
    assert_nil providers_repo.by_id_for_user(provider.id, @owner.id)
    flash = flash_from_redirect(headers, cookie: headers["set-cookie"]&.split(";")&.first)
    assert_equal "Provider deleted.", flash["notice"]
  end

  def test_destroy_foreign_provider_returns_404
    provider = make_provider(@other)
    sign_in(@owner)
    status, _, body = post("/providers/#{provider.id}/delete")
    assert_equal 404, status
    assert parse_json(body).key?("error")
    refute_nil providers_repo.by_id_for_user(provider.id, @other.id)
  end

  def test_destroy_unknown_id_returns_404
    sign_in(@owner)
    status, = post("/providers/999999/delete")
    assert_equal 404, status
  end

  # --- Models proxy ---------------------------------------------------------

  def fetch_models = Space::Server::Actions::Providers::Models::FETCH_MODELS

  def test_models_anon_redirects_with_flash
    provider = make_provider(@owner)
    status, headers, _ = get("/providers/#{provider.id}/models")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_models_foreign_provider_returns_404
    provider = make_provider(@other)
    sign_in(@owner)
    status, = get("/providers/#{provider.id}/models")
    assert_equal 404, status
  end

  def test_models_happy_path_returns_sorted_ids
    provider = make_provider(@owner)
    sign_in(@owner)

    fetch_models.stub(:call, ->(_base_url, _ref) { ["claude-3", "gpt-4", "gpt-4.1"] }) do
      status, _, body = get("/providers/#{provider.id}/models")
      assert_equal 200, status
      payload = parse_json(body)
      assert_equal ["claude-3", "gpt-4", "gpt-4.1"], payload["models"]
      assert_nil payload["error"]
    end
  end

  def test_models_upstream_error_returns_safe_token
    provider = make_provider(@owner)
    sign_in(@owner)

    fetch_models.stub(:call, ->(_base_url, _ref) { raise Space::Server::Operations::FetchModels::UpstreamError, "status 500: <html>super secret upstream body</html>" }) do
      status, _, body = get("/providers/#{provider.id}/models")
      assert_equal 200, status
      payload = parse_json(body)
      assert_equal [], payload["models"]
      assert_equal "upstream_error", payload["error"]
      refute_match(/secret upstream body/, body.respond_to?(:join) ? body.join : body.to_s)
    end
  end

  def test_models_timeout_returns_safe_token
    provider = make_provider(@owner)
    sign_in(@owner)

    fetch_models.stub(:call, ->(_base_url, _ref) { raise Async::TimeoutError, "timed out" }) do
      status, _, body = get("/providers/#{provider.id}/models")
      assert_equal 200, status
      payload = parse_json(body)
      assert_equal [], payload["models"]
      assert_equal "timeout", payload["error"]
    end
  end

  def test_models_secret_resolution_failure_returns_safe_token_without_leaking
    provider = make_provider(@owner)
    sign_in(@owner)

    fetch_models.stub(:call, ->(_base_url, _ref) { raise Space::Server::Operations::FetchModels::SecretResolutionError, "op read failed for op://vault/item" }) do
      status, _, body = get("/providers/#{provider.id}/models")
      assert_equal 200, status
      payload = parse_json(body)
      assert_equal [], payload["models"]
      assert_equal "secret_resolution_failed", payload["error"]
    end
  end

  # --- pi extension generation -----------------------------------------------

  def pi_extension_fetch_models = Space::Server::Actions::Providers::PiExtension::FETCH_MODELS

  def test_pi_extension_anon_redirects_with_flash
    provider = make_provider(@owner)
    status, headers, _ = get("/providers/#{provider.id}/pi_extension")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_pi_extension_foreign_provider_returns_404
    provider = make_provider(@other)
    sign_in(@owner)
    status, = get("/providers/#{provider.id}/pi_extension")
    assert_equal 404, status
  end

  def test_pi_extension_happy_path_keyless_provider
    provider = make_provider(@owner, api_key_ref: nil)
    sign_in(@owner)

    pi_extension_fetch_models.stub(:call, ->(_base_url, _ref) { ["model-a", "model-b"] }) do
      status, _, body = get("/providers/#{provider.id}/pi_extension")
      assert_equal 200, status
      payload = parse_json(body)
      assert_nil payload["error"]
      extension = payload["extension"]
      assert_equal "/root/.pi/agent/extensions/gateway.ts", extension["path"]
      assert_nil extension["env_key"]
      assert_includes extension["content"], 'apiKey: "local-proxy"'
      assert_includes extension["content"], 'id: "model-a"'
      assert_includes extension["content"], 'id: "model-b"'
    end
  end

  def test_pi_extension_happy_path_key_bearing_provider
    provider = make_provider(@owner, api_key_ref: "op://vault/item")
    sign_in(@owner)

    pi_extension_fetch_models.stub(:call, ->(_base_url, _ref) { ["model-a"] }) do
      status, _, body = get("/providers/#{provider.id}/pi_extension")
      assert_equal 200, status
      payload = parse_json(body)
      extension = payload["extension"]
      assert_equal "PI_PROVIDER_API_KEY", extension["env_key"]
      assert_includes extension["content"], "process.env.PI_PROVIDER_API_KEY"
      refute_includes extension["content"], "op://vault/item"
    end
  end

  def test_pi_extension_upstream_error_returns_safe_token
    provider = make_provider(@owner)
    sign_in(@owner)

    pi_extension_fetch_models.stub(:call, ->(_base_url, _ref) { raise Space::Server::Operations::FetchModels::UpstreamError, "status 500" }) do
      status, _, body = get("/providers/#{provider.id}/pi_extension")
      assert_equal 200, status
      payload = parse_json(body)
      assert_nil payload["extension"]
      assert_equal "upstream_error", payload["error"]
    end
  end

  # --- Operations::FetchModels (unit — injected fake http/secret_resolver, no
  # network, no op) --------------------------------------------------------

  FakeResponse = Struct.new(:status, :body) do
    def read = body
    def close = nil
  end

  class FakeHttp
    def initialize(response) = @response = response
    def get(url, headers) = (@last_call = [url, headers]) && @response
    attr_reader :last_call
  end

  class FakeSecretResolver
    def initialize(values) = @values = values
    def call(refs) = refs.to_h { |r| [r["name"], @values.fetch(r["ref"])] }
  end

  def test_fetch_models_sorts_ids_and_sends_bearer_header
    http = FakeHttp.new(FakeResponse.new(200, JSON.generate(data: [{id: "b"}, {id: "a"}])))
    resolver = FakeSecretResolver.new("op://vault/item" => "sekret")
    fetcher = Space::Server::Operations::FetchModels.new(http: http, secret_resolver: resolver)

    result = Sync { fetcher.call("https://api.example.com", "op://vault/item") }

    assert_equal ["a", "b"], result
    url, headers = http.last_call
    assert_equal "https://api.example.com/v1/models", url
    assert_equal [["authorization", "Bearer sekret"]], headers
  end

  def test_fetch_models_omits_auth_header_without_ref
    http = FakeHttp.new(FakeResponse.new(200, JSON.generate(data: [])))
    fetcher = Space::Server::Operations::FetchModels.new(http: http, secret_resolver: FakeSecretResolver.new({}))

    Sync { fetcher.call("https://api.example.com", nil) }

    _, headers = http.last_call
    assert_equal [], headers
  end

  def test_fetch_models_raises_upstream_error_on_non_200
    http = FakeHttp.new(FakeResponse.new(500, "boom"))
    fetcher = Space::Server::Operations::FetchModels.new(http: http, secret_resolver: FakeSecretResolver.new({}))

    assert_raises(Space::Server::Operations::FetchModels::UpstreamError) { Sync { fetcher.call("https://api.example.com", nil) } }
  end

  def test_fetch_models_raises_upstream_error_on_unparseable_body
    http = FakeHttp.new(FakeResponse.new(200, "not json"))
    fetcher = Space::Server::Operations::FetchModels.new(http: http, secret_resolver: FakeSecretResolver.new({}))

    assert_raises(Space::Server::Operations::FetchModels::UpstreamError) { Sync { fetcher.call("https://api.example.com", nil) } }
  end

  def test_fetch_models_raises_secret_resolution_error_when_resolver_fails
    http = FakeHttp.new(FakeResponse.new(200, JSON.generate(data: [])))
    resolver = FakeSecretResolver.new({})
    fetcher = Space::Server::Operations::FetchModels.new(http: http, secret_resolver: resolver)

    assert_raises(Space::Server::Operations::FetchModels::SecretResolutionError) { fetcher.call("https://api.example.com", "op://vault/missing") }
  end
end
