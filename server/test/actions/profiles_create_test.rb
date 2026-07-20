# frozen_string_literal: true

require_relative "action_test_helper"

class ProfilesCreateTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:profiles].delete
    OmniAuth.config.test_mode = true
    @owner        = Factory[:user, github_uid: "profiles-create-owner", username: "profiles-create-owner"]
    @profiles_repo = Space::Server::App["repos.profiles_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def valid_params
    {
      name: "my-profile",
      harness: {
        type: "claude", model: "claude-sonnet-5",
        backend: { base_url: "https://api.example.com/v1", api_key_ref: "op://vault/item" },
        args: ["--flag"]
      },
      environment: {
        env: { FOO: "bar" },
        secrets: [{ ref: "op://vault/item2", name: "API_KEY" }],
        deps: ["git"],
        permissions: { network: "true", mounts: ["/tmp"] }
      }
    }
  end

  # Follows a redirect to /profiles/new and returns props.errors — mirrors
  # jobs_test.rb's contract-failure assertion pattern.
  def errors_after(bad_params)
    sign_in(@owner)
    status, headers, _ = post("/profiles", params: bad_params)
    assert_equal 302, status
    assert_equal "/profiles/new", headers["location"]
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/profiles/new", cookie: redirect_cookie)
    parse_json(body).dig("props", "errors")
  end

  def test_create_anon_redirects_with_flash
    status, headers, _ = post("/profiles", params: valid_params)
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_create_valid_spec_redirects_to_index_with_flash
    sign_in(@owner)
    status, headers, _ = post("/profiles", params: valid_params)
    assert_equal 302, status
    assert_equal "/profiles", headers["location"]
    profile = @profiles_repo.list_for_user(@owner.id).first
    refute_nil profile
    flash = flash_from_redirect(headers, cookie: headers["set-cookie"]&.split(";")&.first)
    assert_equal "Profile created.", flash["notice"]
  end

  def test_create_persists_row_with_validated_spec_and_denormalized_harness_type
    sign_in(@owner)
    post("/profiles", params: valid_params)
    profile = @profiles_repo.list_for_user(@owner.id).first
    refute_nil profile
    assert_equal @owner.id, profile.user_id
    assert_equal "my-profile", profile.name
    assert_equal "claude", profile.harness_type
    assert_equal "claude", profile.spec.dig("harness", "type")
    refute profile.spec.key?("name")
    assert_equal ["op://vault/item2"], profile.spec.dig("environment", "secrets").map { |s| s["ref"] }
    assert_equal true, profile.spec.dig("environment", "permissions", "network")
  end

  def test_create_minimal_spec_applies_defaults
    sign_in(@owner)
    minimal = {
      name: "minimal",
      harness: { type: "claude", model: "sonnet", backend: { base_url: "https://api.example.com" } },
      environment: { deps: ["git"] }
    }
    post("/profiles", params: minimal)
    profile = @profiles_repo.list_for_user(@owner.id).first
    assert_equal({}, profile.spec.dig("environment", "env"))
    assert_equal [], profile.spec.dig("environment", "secrets")
    assert_equal ["git"], profile.spec.dig("environment", "deps")
  end

  def test_create_missing_name_names_field
    errors = errors_after(valid_params.reject { |k, _| k == :name })
    assert errors["name"]
  end

  def test_create_non_http_base_url_names_field
    bad = valid_params.merge(harness: valid_params[:harness].merge(backend: { base_url: "not-a-url" }))
    errors = errors_after(bad)
    assert errors["base_url"]
  end

  def test_create_unknown_harness_type_names_field
    bad = valid_params.merge(harness: valid_params[:harness].merge(type: "gpt4"))
    errors = errors_after(bad)
    assert errors["harness_type"]
  end

  def test_create_secret_ref_not_op_names_field
    bad = valid_params.merge(environment: { secrets: [{ ref: "not-op", name: "X" }] })
    errors = errors_after(bad)
    assert errors["secrets"]
  end

  def test_create_invalid_spec_does_not_persist_a_row
    sign_in(@owner)
    before = @profiles_repo.list_for_user(@owner.id).size
    post("/profiles", params: valid_params.reject { |k, _| k == :name })
    assert_equal before, @profiles_repo.list_for_user(@owner.id).size
  end

end
