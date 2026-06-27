# frozen_string_literal: true

require_relative "../test_helper"

# G1 (crux): Conversation struct predicate tests — 8 oracle scenarios.
# Structs are loaded via conversations_repo.with_messages_and_shares so that
# :messages and :shares associations are combined (required by the predicates).
# Users are loaded via users_repo so Space::Server::Structs::User (with org_ids) is used.
class ConversationStructTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each { |t| conn[t].delete }

    @repo       = Space::Server::App["repos.conversations_repo"]
    @users_repo = Space::Server::App["repos.users_repo"]
    @msg_repo   = Space::Server::App["repos.messages_repo"]

    @owner      = load_user(Factory[:user, github_uid: "1",  username: "owner"])
    @stranger   = load_user(Factory[:user, github_uid: "2",  username: "stranger"])
    @grantee    = load_user(Factory[:user, github_uid: "99", username: "grantee"])
    @org_member = load_user(Factory[:user, github_uid: "7",  username: "member",
                                    github_orgs: [{ "id" => "55", "login" => "acme" }]])

    @conv  = Factory[:conversation, user_id: @owner.id, published: false]
    @msg1  = Factory[:message, conversation_id: @conv.id, role: "user",
                     content: [{ "type" => "text", "text" => "go" }],
                     position: 0, published: false]
    @msg2  = Factory[:message, conversation_id: @conv.id, role: "assistant",
                     content: [{ "type" => "text", "text" => "done" }],
                     position: 1, published: false]
  end

  def load_user(u)
    @users_repo.by_pk(u.id)
  end

  def load
    @repo.with_messages_and_shares(@conv.id)
  end

  def grant(access, kind: "user", login: "grantee", id: "99")
    Factory[:conversation_share, conversation_id: @conv.id,
            grantee_kind: kind, github_login: login, github_id: id, access: access]
  end

  # 1. Private — invisible without a grant
  def test_private_conversation_invisible_without_grant
    conv = load
    refute conv.visible_to?(nil),        "nil (anon) must not see private conv"
    refute conv.visible_to?(@stranger),  "stranger must not see private conv"
    assert conv.visible_to?(@owner),     "owner must see own conv"
  end

  # 2. View grant — grantee sees full transcript
  def test_view_grant_opens_full_transcript_to_grantee
    grant("view")
    conv = load

    assert conv.visible_to?(@grantee),         "view grantee must be visible"
    assert_equal [@msg1.id, @msg2.id],
                 conv.visible_messages(@grantee).map(&:id),
                 "view grantee must receive all messages"
    refute conv.visible_to?(@stranger),        "stranger still excluded"
    refute conv.visible_to?(nil)
  end

  # 3. Org grant — only cached members match
  def test_org_grant_matches_only_cached_members
    grant("view", kind: "org", login: "acme", id: "55")
    conv = load

    assert conv.visible_to?(@org_member),  "org member must be visible"
    assert_equal [@msg1.id, @msg2.id],
                 conv.visible_messages(@org_member).map(&:id)
    refute conv.visible_to?(@grantee),     "non-member stays out"
  end

  # 4. Non-grantee with a published snippet sees only published messages
  def test_snippet_visibility_shows_published_messages_only_to_non_grantee
    @msg_repo.update(@msg1.id, published: true, updated_at: Time.now)
    conv = load

    assert conv.visible_to?(@stranger),     "published snippet makes conv visible"
    assert_equal [@msg1.id],
                 conv.visible_messages(@stranger).map(&:id),
                 "non-grantee must only receive published messages"
  end

  # 5. View grant does NOT allow noting
  def test_view_grant_does_not_allow_noting
    grant("view")
    conv = load

    assert conv.annotatable_by?(@owner),    "owner can always note"
    refute conv.annotatable_by?(@grantee),  "view grantee must not be able to note"
    refute conv.annotatable_by?(@stranger)
    refute conv.annotatable_by?(nil)
  end

  # 6. Note grant implies view and allows noting
  def test_note_grant_implies_view_and_allows_noting
    grant("note")
    conv = load

    assert conv.visible_to?(@grantee),     "note grantee must be visible"
    assert conv.annotatable_by?(@grantee), "note grantee must be able to note"
  end

  # 7. Org note grant — members can note
  def test_org_note_grant_allows_members_to_note
    grant("note", kind: "org", login: "acme", id: "55")
    conv = load

    assert conv.annotatable_by?(@org_member), "org note member must be able to note"
    refute conv.annotatable_by?(@grantee),    "non-member excluded"
  end

  # 8. Published — visible to all, but noting is owner-only
  def test_published_conv_visible_to_all_but_noting_requires_ownership
    @repo.update(@conv.id, published: true, updated_at: Time.now)
    conv = load

    assert conv.visible_to?(nil),        "published conv visible to anon"
    assert conv.visible_to?(@stranger),  "published conv visible to stranger"
    assert_equal [@msg1.id, @msg2.id],
                 conv.visible_messages(@stranger).map(&:id),
                 "published conv shows all messages to anyone"
    refute conv.annotatable_by?(@stranger), "published conv is view-only for the world"
  end
end
