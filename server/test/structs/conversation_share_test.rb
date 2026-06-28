# frozen_string_literal: true

require_relative "../test_helper"

# G1 (crux): ConversationShare predicate tests mirroring oracle model tests.
# Shares are loaded via the combined repo finder so Space::Server::Structs::Share
# (with grants?/matches? inherited from ConversationShare) is used.
# Users are loaded via users_repo so Space::Server::Structs::User (with org_ids) is used.
class ConversationShareStructTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each { |t| conn[t].delete }

    @repo       = Space::Server::App["repos.conversations_repo"]
    @users_repo = Space::Server::App["repos.users_repo"]

    @owner = load_user(Factory[:user, github_uid: "owner-1"])
    @conv  = Factory[:conversation, user_id: @owner.id]
    Factory[:message, conversation_id: @conv.id, role: "user", content: [], position: 0]
  end

  def load_user(u)
    @users_repo.by_pk(u.id)
  end

  # Create a share in DB and reload via the combined finder.
  def grant(**overrides)
    defaults = { conversation_id: @conv.id, grantee_kind: "user",
                 github_login: "octocat", github_id: "99", access: "view" }
    s = Factory[:conversation_share, **defaults.merge(overrides)]
    @repo.with_messages_and_shares(@conv.id).shares.find { |r| r.id == s.id }
  end

  # grants? — ACCESS_RANK: note(1) ⊇ view(0)
  def test_note_access_grants_view_and_note
    s = grant(access: "note")
    assert s.grants?(:view),  "note must grant view (note ⊇ view)"
    assert s.grants?(:note),  "note must grant note"
  end

  def test_view_access_grants_view_not_note
    s = grant(access: "view")
    assert s.grants?(:view),  "view must grant view"
    refute s.grants?(:note),  "view must not grant note"
  end

  # matches? — user kind matches by stable github_uid; org kind by cached org_ids
  def test_user_share_matches_by_github_uid
    s = grant(grantee_kind: "user", github_id: "99")
    viewer     = load_user(Factory[:user, github_uid: "99"])
    org_member = load_user(Factory[:user, github_uid: "7",
                                   github_orgs: [{ "id" => "55", "login" => "acme" }]])

    assert s.matches?(viewer),      "user share must match same github_uid"
    refute s.matches?(org_member),  "user share must not match different uid"
  end

  def test_org_share_matches_by_cached_org_membership
    s = grant(grantee_kind: "org", github_login: "acme", github_id: "55")
    org_member = load_user(Factory[:user, github_uid: "7",
                                   github_orgs: [{ "id" => "55", "login" => "acme" }]])
    viewer = load_user(Factory[:user, github_uid: "99"])

    assert s.matches?(org_member), "org share must match a cached member"
    refute s.matches?(viewer),     "org share must not match a non-member"
  end
end
