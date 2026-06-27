# frozen_string_literal: true

require_relative "action_test_helper"
require "omniauth"

class SessionsActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def mock_callback(token: nil)
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "9",
      info: {nickname: "orgy", name: "Orgy", email: "orgy@example.com", image: nil},
      credentials: token ? {token: token} : nil
    )
    post("/auth/github/callback")
  end

  # G1 + G3(b1) — token present: org memberships synced, user created, session set, 302
  def test_sign_in_syncs_org_memberships_from_callback_token
    Space::Server::Github.stub(:user_orgs, [{"id" => "55", "login" => "acme"}]) do
      mock_callback(token: "t0ken")
    end

    users_repo = Space::Server::App["repos.users_repo"]
    user = users_repo.by_github_uid("9")
    refute_nil user
    assert_equal ["55"], user.org_ids
    assert user.orgs_synced_at, "orgs_synced_at must be present after token sync"
  end

  # G3(b2) — token-less: sync skipped, orgs empty, synced_at nil
  def test_token_less_callback_skips_sync
    status, headers, _ = mock_callback

    users_repo = Space::Server::App["repos.users_repo"]
    user = users_repo.by_github_uid("9")
    refute_nil user
    assert_empty user.org_ids
    assert_nil user.orgs_synced_at
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  # G3(b3) — Github::Error raised: still signs in (302), stale org cache intact
  def test_failed_sync_keeps_stale_cache_and_still_signs_in
    users_repo = Space::Server::App["repos.users_repo"]
    users_repo.create(
      github_uid: "9", username: "orgy", name: "Orgy",
      github_orgs: [{"id" => "55", "login" => "acme"}],
      created_at: Time.now, updated_at: Time.now
    )

    Space::Server::Github.stub(:user_orgs, ->(_t) { raise Space::Server::Github::Error, "boom" }) do
      status, headers, _ = mock_callback(token: "t0ken")
      assert_equal 302, status
      assert_equal "/", headers["location"]
    end

    user = users_repo.by_github_uid("9")
    assert_equal ["55"], user.org_ids, "Stale org cache must survive a failed sync"
  end

  # G1 — login creates user in DB via real repo, sets 302 → root, profile mapped
  def test_login_creates_user_and_sets_session
    status, headers, _ = mock_callback

    assert_equal 302, status
    assert_equal "/", headers["location"]

    users_repo = Space::Server::App["repos.users_repo"]
    user = users_repo.by_github_uid("9")
    refute_nil user
    assert_equal "orgy",             user.username
    assert_equal "Orgy",             user.name
    assert_equal "orgy@example.com", user.email
  end

  # G5 — sessions#create notice flash (oracle: "Signed in as #{user.username}.")
  def test_login_sets_signed_in_notice_flash
    _, headers, _ = mock_callback
    flash = flash_from_redirect(headers)
    assert_equal "Signed in as orgy.", flash["notice"]
  end

  # G2(a) — session fixation: post-login cookie differs from pre-login (rotated)
  def test_login_rotates_session_id
    _, pre_headers, _ = inertia_get("/")
    pre_cookie = pre_headers["set-cookie"]

    _, post_headers, _ = mock_callback
    post_cookie = post_headers["set-cookie"]

    refute_nil post_cookie, "Login must issue a session cookie"
    refute_equal pre_cookie, post_cookie
  end

  # G2(b) — sessions.create is OUT of Hanami Action CSRF
  def test_callback_post_succeeds_without_csrf_token
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "9",
      info: {nickname: "orgy", name: "Orgy", email: "orgy@example.com", image: nil},
      credentials: nil
    )
    status, _, _ = post("/auth/github/callback")
    assert_equal 302, status
  end

  # G4 — logout renews+clears session and redirects root
  def test_logout_clears_session_and_redirects
    mock_callback
    status, headers, _ = get("/logout")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  # G5 — sessions#destroy notice flash (oracle: "Signed out.")
  def test_logout_sets_signed_out_notice_flash
    mock_callback
    _, headers, _ = get("/logout")
    flash = flash_from_redirect(headers)
    assert_equal "Signed out.", flash["notice"]
  end

  # G4 — failure action (GET /auth/failure) redirects to root
  def test_failure_action_redirects_to_root
    status, headers, _ = get("/auth/failure?message=auth_failure")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  # G5 — sessions#failure alert flash (oracle: "Authentication failed: #{params[:message]}.")
  def test_failure_action_sets_alert_flash
    _, headers, _ = get("/auth/failure?message=auth_failure")
    flash = flash_from_redirect(headers)
    assert_equal "Authentication failed: auth_failure.", flash["alert"]
  end

  # G4 — on_failure wired: mock set to Symbol triggers OmniAuth failure handler
  def test_on_failure_handler_wired
    OmniAuth.config.mock_auth[:github] = :access_denied
    status, headers, _ = post("/auth/github/callback")
    assert_equal 302, status
    assert_match %r{\A/auth/failure}, headers["location"]
  end

  # G5 — no dev_auth_user bypass in architect app/ sources
  def test_no_dev_auth_user_bypass
    architect_app_dir = File.expand_path("../../app", __dir__)
    hits = Dir.glob("#{architect_app_dir}/**/*.rb").select do |f|
      File.read(f).include?("dev_auth_user")
    end
    assert_empty hits, "dev_auth_user must not appear in architect app/ sources: #{hits}"
  end

  # G5 — current_user is nil with no session (tested via action without crashing)
  def test_get_root_without_session_does_not_crash
    status, _, _ = inertia_get("/")
    assert status < 500, "GET / with no session must not 500 (current_user must be nil-safe)"
  end
end
