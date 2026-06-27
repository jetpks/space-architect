# frozen_string_literal: true

require_relative "action_test_helper"

# L1-G1 + L1-G2: shares/{create,update,destroy} redirect + flash parity with
# oracle shares_controller.rb:7-41. Github.lookup is always stubbed — no live API.
class SharesActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @owner      = Factory[:user, github_uid: "shares-owner-uid", username: "shares-owner"]
    @conv       = Factory[:conversation, user_id: @owner.id, published: false]
    @shares_repo = Architect::App["repos.conversation_shares_repo"]

    sign_in(@owner)
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def user_account(login: "octocat", id: "42")
    Architect::Github::Account.new(id: id, login: login, kind: "user")
  end

  def org_account(login: "acme-org", id: "99")
    Architect::Github::Account.new(id: id, login: login, kind: "org")
  end

  def share_params(login: "octocat", access: "view")
    { "share" => { "login" => login, "access" => access } }
  end

  # ── shares#create — user account ────────────────────────────────────────────

  def test_create_user_redirects_back
    Architect::Github.stub(:lookup, user_account) do
      status, _, _ = post("/conversations/#{@conv.id}/shares", params: share_params)
      assert_equal 302, status
    end
  end

  def test_create_user_notice_shared_with_login
    Architect::Github.stub(:lookup, user_account(login: "octocat")) do
      _, headers, _ = post("/conversations/#{@conv.id}/shares", params: share_params(login: "octocat"))
      flash = flash_from_redirect(headers)
      assert_equal "Shared with octocat.", flash["notice"]
    end
  end

  def test_create_user_persists_row
    Architect::Github.stub(:lookup, user_account(login: "octocat", id: "42")) do
      post("/conversations/#{@conv.id}/shares", params: share_params(login: "octocat"))
    end
    rows = @shares_repo.for_conversation(@conv.id)
    assert_equal 1, rows.size
    row = rows.first
    assert_equal "user",    row.grantee_kind
    assert_equal "octocat", row.github_login
    assert_equal "42",      row.github_id
    assert_equal "view",    row.access
  end

  # ── shares#create — org account ─────────────────────────────────────────────

  def test_create_org_notice_shared_with_members
    Architect::Github.stub(:lookup, org_account(login: "acme-org")) do
      _, headers, _ = post("/conversations/#{@conv.id}/shares", params: share_params(login: "acme-org"))
      flash = flash_from_redirect(headers)
      assert_equal "Shared with members of acme-org.", flash["notice"]
    end
  end

  def test_create_org_persists_row_with_org_kind
    Architect::Github.stub(:lookup, org_account(login: "acme-org", id: "99")) do
      post("/conversations/#{@conv.id}/shares", params: share_params(login: "acme-org"))
    end
    row = @shares_repo.for_conversation(@conv.id).first
    assert_equal "org", row.grantee_kind
    assert_equal "acme-org", row.github_login
  end

  # ── shares#create — access defaults to "view" when blank ────────────────────

  def test_create_defaults_access_to_view_when_not_provided
    Architect::Github.stub(:lookup, user_account) do
      post("/conversations/#{@conv.id}/shares",
           params: { "share" => { "login" => "octocat" } })
    end
    row = @shares_repo.for_conversation(@conv.id).first
    assert_equal "view", row.access
  end

  # ── shares#create — Github::NotFound ────────────────────────────────────────

  def test_create_not_found_redirects_back
    Architect::Github.stub(:lookup, ->(_l) { raise Architect::Github::NotFound, "not found" }) do
      status, _, _ = post("/conversations/#{@conv.id}/shares", params: share_params(login: "nobody"))
      assert_equal 302, status
    end
  end

  def test_create_not_found_alert
    Architect::Github.stub(:lookup, ->(_l) { raise Architect::Github::NotFound, "not found" }) do
      _, headers, _ = post("/conversations/#{@conv.id}/shares", params: share_params(login: "nobody"))
      flash = flash_from_redirect(headers)
      assert_equal "No GitHub user or organization named nobody.", flash["alert"]
    end
  end

  def test_create_not_found_no_row_persisted
    Architect::Github.stub(:lookup, ->(_l) { raise Architect::Github::NotFound, "not found" }) do
      post("/conversations/#{@conv.id}/shares", params: share_params(login: "nobody"))
    end
    assert_equal 0, @shares_repo.for_conversation(@conv.id).size
  end

  # ── shares#create — Github::Error ───────────────────────────────────────────

  def test_create_github_error_redirects_back
    Architect::Github.stub(:lookup, ->(_l) { raise Architect::Github::Error, "boom" }) do
      status, _, _ = post("/conversations/#{@conv.id}/shares", params: share_params)
      assert_equal 302, status
    end
  end

  def test_create_github_error_alert
    Architect::Github.stub(:lookup, ->(_l) { raise Architect::Github::Error, "boom" }) do
      _, headers, _ = post("/conversations/#{@conv.id}/shares", params: share_params)
      flash = flash_from_redirect(headers)
      assert_equal "GitHub lookup failed — try again.", flash["alert"]
    end
  end

  def test_create_github_error_no_row_persisted
    Architect::Github.stub(:lookup, ->(_l) { raise Architect::Github::Error, "boom" }) do
      post("/conversations/#{@conv.id}/shares", params: share_params)
    end
    assert_equal 0, @shares_repo.for_conversation(@conv.id).size
  end

  # ── shares#create — duplicate ────────────────────────────────────────────────

  def test_create_duplicate_redirects_back
    Architect::Github.stub(:lookup, user_account(login: "octocat", id: "42")) do
      post("/conversations/#{@conv.id}/shares", params: share_params(login: "octocat"))
      status, _, _ = post("/conversations/#{@conv.id}/shares", params: share_params(login: "octocat"))
      assert_equal 302, status
    end
  end

  def test_create_duplicate_alert
    Architect::Github.stub(:lookup, user_account(login: "octocat", id: "42")) do
      post("/conversations/#{@conv.id}/shares", params: share_params(login: "octocat"))
      _, headers, _ = post("/conversations/#{@conv.id}/shares", params: share_params(login: "octocat"))
      flash = flash_from_redirect(headers)
      assert_equal "Github login has already been taken.", flash["alert"]
    end
  end

  def test_create_duplicate_no_second_row
    Architect::Github.stub(:lookup, user_account(login: "octocat", id: "42")) do
      post("/conversations/#{@conv.id}/shares", params: share_params(login: "octocat"))
      post("/conversations/#{@conv.id}/shares", params: share_params(login: "octocat"))
    end
    assert_equal 1, @shares_repo.for_conversation(@conv.id).size
  end

  # ── shares#update ────────────────────────────────────────────────────────────

  def test_update_success_redirects_back
    share = Factory[:conversation_share, conversation_id: @conv.id,
                    github_login: "octocat", access: "view"]
    status, _, _ = patch("/conversations/#{@conv.id}/shares/#{share.id}",
                          params: { "share" => { "access" => "note" } })
    assert_equal 302, status
  end

  def test_update_success_notice
    share = Factory[:conversation_share, conversation_id: @conv.id,
                    github_login: "octocat", access: "view"]
    _, headers, _ = patch("/conversations/#{@conv.id}/shares/#{share.id}",
                           params: { "share" => { "access" => "note" } })
    flash = flash_from_redirect(headers)
    assert_equal "Access updated for octocat.", flash["notice"]
  end

  def test_update_success_persists_new_access
    share = Factory[:conversation_share, conversation_id: @conv.id,
                    github_login: "octocat", access: "view"]
    patch("/conversations/#{@conv.id}/shares/#{share.id}",
          params: { "share" => { "access" => "note" } })
    updated = @shares_repo.by_pk(share.id)
    assert_equal "note", updated.access
  end

  def test_update_contract_failure_redirects_back_with_alert
    share = Factory[:conversation_share, conversation_id: @conv.id,
                    github_login: "octocat", access: "view"]
    status, headers, _ = patch("/conversations/#{@conv.id}/shares/#{share.id}",
                                params: { "share" => { "access" => "" } })
    assert_equal 302, status
    flash = flash_from_redirect(headers)
    refute_nil flash["alert"]
  end

  # ── shares#destroy ────────────────────────────────────────────────────────────

  def test_destroy_success_redirects_back
    share = Factory[:conversation_share, conversation_id: @conv.id,
                    github_login: "octocat", access: "view"]
    status, _, _ = delete("/conversations/#{@conv.id}/shares/#{share.id}")
    assert_equal 302, status
  end

  def test_destroy_success_notice
    share = Factory[:conversation_share, conversation_id: @conv.id,
                    github_login: "octocat", access: "view"]
    _, headers, _ = delete("/conversations/#{@conv.id}/shares/#{share.id}")
    flash = flash_from_redirect(headers)
    assert_equal "Share removed for octocat.", flash["notice"]
  end

  def test_destroy_removes_row
    share = Factory[:conversation_share, conversation_id: @conv.id,
                    github_login: "octocat", access: "view"]
    delete("/conversations/#{@conv.id}/shares/#{share.id}")
    assert_nil @shares_repo.by_pk(share.id)
  end
end
