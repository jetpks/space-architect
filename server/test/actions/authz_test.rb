# frozen_string_literal: true

require_relative "action_test_helper"

# G2/G3 (crux): B2 inversion — authz/visibility guards now redirect+flash.
# G3: Index scope (published ∪ owned ∪ shared; anon → published; empty org_ids safe).
# G4: visible_messages data-scoping (snippet viewers get only published messages).
# G4: can_note / can_manage seam in show props.
#
# All render paths use inertia_get (X-Inertia). PATCH/DELETE guard rows use
# inertia_patch/inertia_delete to trigger the middleware 302→303 coercion.
class AuthzActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @conv_repo = Architect::App["repos.conversations_repo"]
    @msg_repo  = Architect::App["repos.messages_repo"]
    @ann_repo  = Architect::App["repos.annotations_repo"]

    @owner     = Factory[:user, github_uid: "uid-owner", username: "owner"]
    @stranger  = Factory[:user, github_uid: "uid-stranger", username: "stranger"]
    @grantee   = Factory[:user, github_uid: "uid-grantee", username: "grantee"]
    @org_member = Factory[:user, github_uid: "uid-member", username: "member",
                           github_orgs: [{ "id" => "org-55", "login" => "acme" }]]

    @conv = Factory[:conversation, user_id: @owner.id, published: false]
    @msg1 = Factory[:message, conversation_id: @conv.id, role: "user",
                    content: [{ "type" => "text", "text" => "q" }], position: 1, published: false]
    @msg2 = Factory[:message, conversation_id: @conv.id, role: "assistant",
                    content: [{ "type" => "text", "text" => "a" }], position: 2, published: false]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def grant(access, kind: "user", login: "grantee", id: "uid-grantee")
    Factory[:conversation_share, conversation_id: @conv.id,
            grantee_kind: kind, github_login: login, github_id: id, access: access]
  end

  # ── conversations/show — visibility guards ──────────────────────────────────

  def test_show_anon_on_invisible_conv_redirects_302
    status, headers, _ = get("/conversations/#{@conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_anon_on_invisible_conv_flash_sign_in_nudge
    _, headers, _ = get("/conversations/#{@conv.id}")
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to view this conversation.", flash["alert"]
  end

  def test_show_signed_in_non_grantee_redirects_302
    sign_in(@stranger)
    status, headers, _ = get("/conversations/#{@conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_signed_in_non_grantee_flash_not_found
    sign_in(@stranger)
    _, headers, _ = get("/conversations/#{@conv.id}")
    flash = flash_from_redirect(headers)
    assert_equal "Not found.", flash["alert"]
  end

  def test_show_owner_returns_200
    sign_in(@owner)
    status, _, body = inertia_get("/conversations/#{@conv.id}")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal @conv.id, data["props"]["conversation"]["id"]
  end

  def test_show_view_grantee_returns_200
    grant("view")
    sign_in(@grantee)
    status, _, _ = inertia_get("/conversations/#{@conv.id}")
    assert_equal 200, status
  end

  # G4: snippet viewer receives only published messages (via turns)
  def test_show_snippet_viewer_receives_only_published_turns
    @msg_repo.update(@msg2.id, published: true, updated_at: Time.now)
    sign_in(@stranger)
    status, _, body = inertia_get("/conversations/#{@conv.id}")
    assert_equal 200, status
    data = parse_json(body)
    all_message_ids = data["props"]["turns"].flat_map do |t|
      [t.dig("prompt", "id")].compact +
        t["rounds"].flat_map { |r| r["messages"].map { |m| m["id"] } }
    end
    assert_includes all_message_ids, @msg2.id,  "published message must be in turns"
    refute_includes all_message_ids, @msg1.id,  "unpublished message must not be in turns"
  end

  # G4: owner receives all messages
  def test_show_owner_receives_all_messages
    @msg_repo.update(@msg1.id, published: true, updated_at: Time.now)
    @msg_repo.update(@msg2.id, published: true, updated_at: Time.now)
    sign_in(@owner)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    all_message_ids = data["props"]["turns"].flat_map do |t|
      [t.dig("prompt", "id")].compact +
        t["rounds"].flat_map { |r| r["messages"].map { |m| m["id"] } }
    end
    assert_includes all_message_ids, @msg1.id
    assert_includes all_message_ids, @msg2.id
  end

  # G4: can_note / can_manage seam
  def test_show_can_manage_and_can_note_for_owner
    sign_in(@owner)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    assert_equal true,  data["props"]["conversation"]["can_manage"], "owner: can_manage must be true"
    assert_equal true,  data["props"]["conversation"]["can_note"],   "owner: can_note must be true"
  end

  def test_show_can_note_true_can_manage_false_for_note_grantee
    grant("note")
    sign_in(@grantee)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    assert_equal false, data["props"]["conversation"]["can_manage"], "note grantee: can_manage must be false"
    assert_equal true,  data["props"]["conversation"]["can_note"],   "note grantee: can_note must be true"
  end

  def test_show_can_note_and_can_manage_false_for_view_grantee
    grant("view")
    sign_in(@grantee)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    assert_equal false, data["props"]["conversation"]["can_manage"]
    assert_equal false, data["props"]["conversation"]["can_note"]
  end

  def test_show_can_note_and_can_manage_false_for_public_viewer_of_published_conv
    @conv_repo.update(@conv.id, published: true, updated_at: Time.now)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    assert_equal false, data["props"]["conversation"]["can_manage"]
    assert_equal false, data["props"]["conversation"]["can_note"]
  end

  def test_show_shares_nil_for_non_owner
    grant("view")
    sign_in(@grantee)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    assert_nil data["props"]["shares"], "non-owner must see nil shares"
  end

  def test_show_shares_array_for_owner
    sign_in(@owner)
    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data = parse_json(body)
    assert_kind_of Array, data["props"]["shares"], "owner must see shares array"
  end

  # ── conversations/new + create ─────────────────────────────────────────────

  def test_new_anon_redirects_302
    status, headers, _ = get("/conversations/new")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_new_anon_flash_sign_in
    _, headers, _ = get("/conversations/new")
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_new_logged_in_returns_200
    sign_in(@owner)
    status, _, body = inertia_get("/conversations/new")
    assert_equal 200, status
    assert_equal "Conversations/New", parse_json(body)["component"]
  end

  def test_create_anon_redirects_302
    status, headers, _ = post("/conversations", params: { "conversation" => { "source_file" => "x.jsonl" } })
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_create_logged_in_does_not_auth_redirect
    # A non-multipart string param hits the "must be a file upload" guard
    # and redirects to /conversations/new (not "/" — the auth gate).
    sign_in(@owner)
    status, headers, _ = post("/conversations", params: { "conversation" => { "source_file" => "x.jsonl" } })
    assert_equal 302, status
    refute_equal "/", headers["location"], "Logged-in create must not hit the auth gate"
  end

  # ── conversations/publish + destroy — PATCH/DELETE → 303 with X-Inertia ───

  def test_publish_anon_redirects_302
    status, headers, _ = patch("/conversations/#{@conv.id}/publish")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_publish_anon_flash_sign_in
    _, headers, _ = patch("/conversations/#{@conv.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_publish_non_owner_redirects_302
    sign_in(@stranger)
    status, headers, _ = patch("/conversations/#{@conv.id}/publish")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_publish_non_owner_flash_not_authorized
    sign_in(@stranger)
    _, headers, _ = patch("/conversations/#{@conv.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Not authorized.", flash["alert"]
  end

  def test_publish_non_owner_inertia_coerces_to_303
    sign_in(@stranger)
    status, _, _ = inertia_patch("/conversations/#{@conv.id}/publish")
    assert_equal 303, status
  end

  def test_publish_owner_redirects_to_conversation
    sign_in(@owner)
    status, headers, _ = patch("/conversations/#{@conv.id}/publish")
    assert_equal 302, status
    assert_equal "/conversations/#{@conv.id}", headers["location"]
  end

  def test_destroy_anon_redirects_302
    status, headers, _ = delete("/conversations/#{@conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_destroy_non_owner_redirects_302
    sign_in(@stranger)
    status, _, _ = delete("/conversations/#{@conv.id}")
    assert_equal 302, status
  end

  def test_destroy_non_owner_inertia_coerces_to_303
    sign_in(@stranger)
    status, _, _ = inertia_delete("/conversations/#{@conv.id}")
    assert_equal 303, status
  end

  def test_destroy_owner_redirects_to_root
    sign_in(@owner)
    status, headers, _ = delete("/conversations/#{@conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  # ── annotations/create ─────────────────────────────────────────────────────

  def ann_params
    { "annotation" => { "body" => "a note", "target_kind" => "conversation" } }
  end

  def test_annotation_create_anon_redirects_302
    status, headers, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_annotation_create_anon_flash_sign_in
    _, headers, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_annotation_create_owner_redirects_back
    sign_in(@owner)
    status, _, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    assert_equal 302, status
    assert_equal 1, @ann_repo.for_conversation(@conv.id).size
  end

  def test_annotation_create_stranger_on_invisible_conv_flash_not_found
    sign_in(@stranger)
    # @conv is private, @stranger has no grant → not visible
    _, headers, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    assert_equal 302, headers["location"] && 302  # location check
    flash = flash_from_redirect(headers)
    assert_equal "Not found.", flash["alert"]
  end

  def test_annotation_create_stranger_on_published_redirects_back
    @conv_repo.update(@conv.id, published: true, updated_at: Time.now)
    sign_in(@stranger)
    status, _, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    assert_equal 302, status
  end

  def test_annotation_create_stranger_on_published_flash_note_access
    @conv_repo.update(@conv.id, published: true, updated_at: Time.now)
    sign_in(@stranger)
    _, headers, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    flash = flash_from_redirect(headers)
    assert_equal "Note access required.", flash["alert"]
  end

  def test_annotation_create_view_grant_flash_note_access
    grant("view")
    sign_in(@grantee)
    _, headers, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    flash = flash_from_redirect(headers)
    assert_equal "Note access required.", flash["alert"]
  end

  def test_annotation_create_note_grant_redirects_back
    grant("note")
    sign_in(@grantee)
    status, _, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    assert_equal 302, status
  end

  def test_annotation_create_org_note_grant_redirects_back
    grant("note", kind: "org", login: "acme", id: "org-55")
    sign_in(@org_member)
    status, _, _ = post("/conversations/#{@conv.id}/annotations", params: ann_params)
    assert_equal 302, status
  end

  # ── annotations/destroy ────────────────────────────────────────────────────

  def test_annotation_destroy_anon_redirects_302
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id]
    status, headers, _ = delete("/annotations/#{ann.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_annotation_destroy_non_owner_returns_404
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id]
    sign_in(@stranger)
    status, _, _ = delete("/annotations/#{ann.id}")
    assert_equal 404, status
  end

  def test_annotation_destroy_owner_redirects_back
    sign_in(@owner)
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id]
    status, _, _ = delete("/annotations/#{ann.id}")
    assert_equal 302, status
  end

  # ── shares (owner-only) ─────────────────────────────────────────────────────

  def share_create_params
    { "share" => { "login" => "octocat", "access" => "view" } }
  end

  def test_share_create_anon_redirects_302
    status, headers, _ = post("/conversations/#{@conv.id}/shares", params: share_create_params)
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_share_create_non_owner_redirects_302
    sign_in(@stranger)
    status, headers, _ = post("/conversations/#{@conv.id}/shares", params: share_create_params)
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_share_create_non_owner_flash_not_authorized
    sign_in(@stranger)
    _, headers, _ = post("/conversations/#{@conv.id}/shares", params: share_create_params)
    flash = flash_from_redirect(headers)
    assert_equal "Not authorized.", flash["alert"]
  end

  def test_share_create_owner_redirects_back
    sign_in(@owner)
    fake_account = Architect::Github::Account.new(id: "42", login: "octocat", kind: "user")
    Architect::Github.stub(:lookup, fake_account) do
      status, _, _ = post("/conversations/#{@conv.id}/shares", params: share_create_params)
      assert_equal 302, status
    end
  end

  def test_share_update_anon_redirects_302
    s = Factory[:conversation_share, conversation_id: @conv.id]
    status, headers, _ = patch("/conversations/#{@conv.id}/shares/#{s.id}",
                                params: { "share" => { "access" => "note" } })
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_share_update_non_owner_redirects_302
    s = Factory[:conversation_share, conversation_id: @conv.id]
    sign_in(@stranger)
    status, _, _ = patch("/conversations/#{@conv.id}/shares/#{s.id}",
                         params: { "share" => { "access" => "note" } })
    assert_equal 302, status
  end

  def test_share_update_non_owner_inertia_coerces_to_303
    s = Factory[:conversation_share, conversation_id: @conv.id]
    sign_in(@stranger)
    status, _, _ = inertia_patch("/conversations/#{@conv.id}/shares/#{s.id}",
                                 params: { "share" => { "access" => "note" } })
    assert_equal 303, status
  end

  def test_share_destroy_anon_redirects_302
    s = Factory[:conversation_share, conversation_id: @conv.id]
    status, headers, _ = delete("/conversations/#{@conv.id}/shares/#{s.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_share_destroy_non_owner_redirects_302
    s = Factory[:conversation_share, conversation_id: @conv.id]
    sign_in(@stranger)
    status, _, _ = delete("/conversations/#{@conv.id}/shares/#{s.id}")
    assert_equal 302, status
  end

  def test_share_destroy_non_owner_inertia_coerces_to_303
    s = Factory[:conversation_share, conversation_id: @conv.id]
    sign_in(@stranger)
    status, _, _ = inertia_delete("/conversations/#{@conv.id}/shares/#{s.id}")
    assert_equal 303, status
  end

  def test_share_destroy_owner_redirects_back
    s = Factory[:conversation_share, conversation_id: @conv.id]
    sign_in(@owner)
    status, _, _ = delete("/conversations/#{@conv.id}/shares/#{s.id}")
    assert_equal 302, status
  end

  # ── messages/publish ───────────────────────────────────────────────────────

  def test_message_publish_anon_redirects_302
    status, headers, _ = patch("/messages/#{@msg1.id}/publish")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_message_publish_anon_flash_sign_in
    _, headers, _ = patch("/messages/#{@msg1.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_message_publish_non_owner_redirects_302
    sign_in(@stranger)
    status, _, _ = patch("/messages/#{@msg1.id}/publish")
    assert_equal 302, status
  end

  def test_message_publish_non_owner_flash_not_authorized
    sign_in(@stranger)
    _, headers, _ = patch("/messages/#{@msg1.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Not authorized.", flash["alert"]
  end

  def test_message_publish_non_owner_inertia_coerces_to_303
    sign_in(@stranger)
    status, _, _ = inertia_patch("/messages/#{@msg1.id}/publish")
    assert_equal 303, status
  end

  def test_message_publish_owner_redirects_to_conversation
    sign_in(@owner)
    status, headers, _ = patch("/messages/#{@msg1.id}/publish")
    assert_equal 302, status
    assert_match %r{/conversations/#{@conv.id}#message-#{@msg1.id}}, headers["location"]
  end

  # ── entities/show — STAYS JSON 404 ─────────────────────────────────────────

  def test_entity_show_invisible_conv_signed_in_returns_404_json
    sign_in(@stranger)
    status, headers, _ = get("/conversations/#{@conv.id}/entities/message-#{@msg1.id}")
    assert_equal 404, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
  end

  def test_entity_show_invisible_conv_anon_returns_404_json
    status, headers, _ = get("/conversations/#{@conv.id}/entities/message-#{@msg1.id}")
    assert_equal 404, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
  end

  # G4: snippet viewer resolves published entity but not unpublished structure
  def test_entity_snippet_viewer_resolves_published_message
    @msg_repo.update(@msg2.id, published: true, updated_at: Time.now)
    sign_in(@stranger)
    status, _, _ = get("/conversations/#{@conv.id}/entities/message-#{@msg2.id}")
    assert_equal 200, status
  end

  def test_entity_snippet_viewer_cannot_resolve_unpublished_turn
    @msg_repo.update(@msg2.id, published: true, updated_at: Time.now)
    sign_in(@stranger)
    status, _, _ = get("/conversations/#{@conv.id}/entities/turn-#{@msg1.id}")
    assert_equal 404, status
  end

  # ── index scope ────────────────────────────────────────────────────────────

  def test_index_anon_returns_only_published_conversations
    pub_conv   = Factory[:conversation, published: true]
    _priv_conv = @conv

    _, _, body = inertia_get("/")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }

    assert_includes ids, pub_conv.id,  "published conv must appear for anon"
    refute_includes ids, @conv.id,     "private conv must not appear for anon"
  end

  def test_index_signed_in_user_sees_own_and_shared
    pub_conv  = Factory[:conversation, published: true]
    own_conv  = @conv

    other_conv = Factory[:conversation, user_id: @owner.id, published: false]
    Factory[:conversation_share, conversation_id: other_conv.id,
            grantee_kind: "user", github_id: @grantee.github_uid,
            github_login: @grantee.username, access: "view"]

    sign_in(@grantee)
    _, _, body = inertia_get("/")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }

    assert_includes ids, pub_conv.id,    "published conv visible to everyone"
    assert_includes ids, other_conv.id,  "shared conv must appear for grantee"
    refute_includes ids, own_conv.id,    "unshared private conv must not appear"
  end

  def test_index_signed_in_owner_sees_own_conversations
    sign_in(@owner)
    _, _, body = inertia_get("/")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }
    assert_includes ids, @conv.id, "owner must see own private conv"
  end

  def test_index_user_with_empty_org_ids_returns_safely
    sign_in(@stranger)
    status, _, body = inertia_get("/")
    assert_equal 200, status
    data = parse_json(body)
    assert_kind_of Array, data["props"]["conversations"]
  end

  def test_index_org_share_visible_to_org_member
    Factory[:conversation_share, conversation_id: @conv.id,
            grantee_kind: "org", github_id: "org-55", github_login: "acme", access: "view"]

    sign_in(@org_member)
    _, _, body = inertia_get("/")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }

    assert_includes ids, @conv.id, "org-shared conv must appear for cached org member"
  end

  def test_index_conversation_list_json_key_set
    Factory[:conversation, published: true]
    _, _, body = inertia_get("/")
    data = parse_json(body)
    conv = data["props"]["conversations"].first
    expected_keys = %w[id title status published turns_count owned shared]
    expected_keys.each do |k|
      assert conv.key?(k), "conversation_list_json must include key #{k.inspect}"
    end
    assert_equal expected_keys.sort, conv.keys.sort, "key set must match exactly"
  end
end
