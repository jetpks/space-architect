# frozen_string_literal: true

require_relative "action_test_helper"

class ProfilesNewTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:profiles].delete
    Space::Server::App["db.gateway"].connection[:providers].delete
    OmniAuth.config.test_mode = true
    @owner          = Factory[:user, github_uid: "profiles-new-owner", username: "profiles-new-owner"]
    @providers_repo = Space::Server::App["repos.providers_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_new_anon_redirects_with_flash
    status, headers, _ = get("/profiles/new")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_new_renders_inertia_page
    sign_in(@owner)
    status, headers, body = inertia_get("/profiles/new")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    assert_equal "Profiles/New", parse_json(body)["component"]
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
end
