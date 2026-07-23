# frozen_string_literal: true

require_relative "action_test_helper"

class JobsNewTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    Space::Server::App["db.gateway"].connection[:profiles].delete
    Space::Server::App["db.gateway"].connection[:providers].delete
    OmniAuth.config.test_mode = true
    @owner          = Factory[:user, github_uid: "jobs-new-owner", username: "jobs-new-owner"]
    @providers_repo = Space::Server::App["repos.providers_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_new_anon_redirects_with_flash
    status, headers, _ = get("/jobs/new")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_new_renders_inertia_page
    sign_in(@owner)
    status, headers, body = inertia_get("/jobs/new")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    assert_equal "Jobs/New", parse_json(body)["component"]
  end

  def test_new_carries_empty_profiles_prop_when_none_exist
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    assert_equal [], parse_json(body).dig("props", "profiles")
  end

  def test_new_carries_own_profiles_ordered_by_name
    other = Factory[:user, github_uid: "jobs-new-other", username: "jobs-new-other"]
    Factory[:profile, user_id: @owner.id, name: "zeta"]
    Factory[:profile, user_id: @owner.id, name: "alpha"]
    Factory[:profile, user_id: other.id, name: "foreign"]

    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    profiles = parse_json(body).dig("props", "profiles")
    assert_equal %w[alpha zeta], profiles.map { |p| p["name"] }
  end

  def test_new_profile_shape
    profile = Factory[:profile, user_id: @owner.id]
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    entry = parse_json(body).dig("props", "profiles").first
    assert_equal profile.id, entry["id"]
    assert_equal profile.name, entry["name"]
    assert_equal "claude", entry["harness_type"]
    assert entry.key?("spec")
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

  # --- GET /jobs/new?from=<job id> — re-run prefill (I45 AC4) ---------------

  def test_new_prefill_spec_present_for_owned_from_job
    job = Factory[:job, user_id: @owner.id]
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new", params: { from: job.id })
    assert_equal job.spec, parse_json(body).dig("props", "prefill_spec")
  end

  def test_new_prefill_spec_absent_for_foreign_job
    other = Factory[:user, github_uid: "jobs-new-foreign", username: "jobs-new-foreign"]
    job = Factory[:job, user_id: other.id]
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new", params: { from: job.id })
    refute parse_json(body)["props"].key?("prefill_spec")
  end

  def test_new_prefill_spec_absent_when_from_param_missing
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new")
    refute parse_json(body)["props"].key?("prefill_spec")
  end

  def test_new_prefill_spec_absent_for_nonexistent_from
    sign_in(@owner)
    _, _, body = inertia_get("/jobs/new", params: { from: 999_999 })
    refute parse_json(body)["props"].key?("prefill_spec")
  end
end
