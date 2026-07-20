# frozen_string_literal: true

require_relative "action_test_helper"

class ProfilesActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:profiles].delete
    Space::Server::App["db.gateway"].connection[:providers].delete
    OmniAuth.config.test_mode = true
    @owner          = Factory[:user, github_uid: "profiles-provider-owner", username: "profiles-provider-owner"]
    @profiles_repo  = Space::Server::App["repos.profiles_repo"]
    @providers_repo = Space::Server::App["repos.providers_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def valid_params
    {
      name: "my-profile",
      spec: {
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
    }
  end

  def make_provider(user, attrs = {})
    now = Time.now
    @providers_repo.create({
      user_id: user.id, name: "gateway", base_url: "https://api.example.com/v1",
      api_key_ref: "op://vault/item", flavors: ["openai"], created_at: now, updated_at: now
    }.merge(attrs))
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

  # --- GET /profiles/new — providers prop (BRIEF I23 shape 1) ---------------

  def test_new_carries_empty_providers_prop_when_none_exist
    sign_in(@owner)
    _, _, body = inertia_get("/profiles/new")
    assert_equal [], parse_json(body).dig("props", "providers")
  end

  def test_new_carries_own_providers_ordered_by_name_with_frozen_shape
    other = Factory[:user, github_uid: "profiles-provider-other", username: "profiles-provider-other"]
    now = Time.now
    @providers_repo.create(user_id: @owner.id, name: "zeta", base_url: "https://z.example.com",
                            api_key_ref: "op://vault/z", flavors: ["openai"], created_at: now, updated_at: now)
    @providers_repo.create(user_id: @owner.id, name: "alpha", base_url: "https://a.example.com",
                            api_key_ref: nil, flavors: [], created_at: now, updated_at: now)
    @providers_repo.create(user_id: other.id, name: "foreign", base_url: "https://f.example.com",
                            api_key_ref: nil, flavors: [], created_at: now, updated_at: now)

    sign_in(@owner)
    _, _, body = inertia_get("/profiles/new")
    providers = parse_json(body).dig("props", "providers")
    assert_equal %w[alpha zeta], providers.map { |p| p["name"] }
    entry = providers.first
    assert_equal %w[api_key_ref base_url flavors id name].sort, entry.keys.sort
  end

  # --- POST /profiles — provider_id provenance (BRIEF I23 shape 2) ----------

  def test_create_without_provider_id_persists_nil
    sign_in(@owner)
    post("/profiles", params: valid_params)
    profile = @profiles_repo.list_for_user(@owner.id).first
    assert_nil profile.provider_id
  end

  def test_create_with_owned_provider_persists_provider_id
    provider = make_provider(@owner)
    sign_in(@owner)
    post("/profiles", params: valid_params.merge(provider_id: provider.id))
    profile = @profiles_repo.list_for_user(@owner.id).first
    assert_equal provider.id, profile.provider_id
  end

  def test_create_with_unknown_provider_id_names_field_and_does_not_persist
    sign_in(@owner)
    before = @profiles_repo.list_for_user(@owner.id).size
    errors = errors_after(valid_params.merge(provider_id: 999_999))
    assert errors["provider_id"]
    assert_equal before, @profiles_repo.list_for_user(@owner.id).size
  end

  def test_create_with_foreign_provider_id_names_field_and_does_not_persist
    other = Factory[:user, github_uid: "profiles-provider-foreign", username: "profiles-provider-foreign"]
    provider = make_provider(other)
    sign_in(@owner)
    before = @profiles_repo.list_for_user(@owner.id).size
    errors = errors_after(valid_params.merge(provider_id: provider.id))
    assert errors["provider_id"]
    assert_equal before, @profiles_repo.list_for_user(@owner.id).size
  end

  def test_deleting_referenced_provider_nulls_profile_provider_id_and_spec_survives
    provider = make_provider(@owner)
    sign_in(@owner)
    post("/profiles", params: valid_params.merge(provider_id: provider.id))
    profile = @profiles_repo.list_for_user(@owner.id).first
    assert_equal provider.id, profile.provider_id

    @providers_repo.delete(provider.id)

    reloaded = @profiles_repo.by_pk(profile.id)
    refute_nil reloaded
    assert_nil reloaded.provider_id
    assert_equal "claude", reloaded.spec.dig("harness", "type")
  end
end
