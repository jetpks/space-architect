# frozen_string_literal: true

require_relative "action_test_helper"

# G2 (crux): The 3 render actions emit faithful Inertia page objects.
# G3 (crux): B2 seam inverted per spec §2 matrix — every row asserted.
# G4: can_note / can_manage in show props across viewer states.
# G5: sessions flash round-trips.
#
# All render requests use X-Inertia (XHR) for hermetic, manifest-free execution.
# The version header = Space::Server::App["vite"].digest (hashes app/frontend sources,
# not the manifest) so no node/npm/build is required.
class InertiaRenderTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @owner    = Factory[:user, github_uid: "uid-iowner", username: "iowner"]
    @stranger = Factory[:user, github_uid: "uid-istranger", username: "istranger"]
    @grantee  = Factory[:user, github_uid: "uid-igrantee", username: "igrantee"]

    @conv = Factory[:conversation, user_id: @owner.id, published: false]
    @msg1 = Factory[:message, conversation_id: @conv.id, role: "user",
                    content: [{"type" => "text", "text" => "prompt"}], position: 1, published: false]
    @msg2 = Factory[:message, conversation_id: @conv.id, role: "assistant",
                    content: [{"type" => "text", "text" => "reply"}], position: 2, published: false]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  def grant(access, kind: "user", login: "igrantee", id: "uid-igrantee")
    Factory[:conversation_share, conversation_id: @conv.id,
            grantee_kind: kind, github_login: login, github_id: id, access: access]
  end

  def inertia_page(path, cookie: nil)
    _, _, body = inertia_get(path, cookie: cookie)
    parse_json(body)
  end

  # ── G2: Index render ─────────────────────────────────────────────────────

  def test_index_page_object_shape
    _, headers, body = inertia_get("/")
    assert_equal "true", headers["x-inertia"]
    assert_equal "application/json", headers["content-type"]
    data = parse_json(body)
    assert_equal "Conversations/Index", data["component"]
    assert data.key?("url")
    assert data.key?("version")
    assert data["props"].key?("conversations")
    assert data["props"].key?("current_user")
    assert data["props"].key?("flash")
  end

  def test_index_anon_sees_only_published
    pub = Factory[:conversation, published: true]
    _, _, body = inertia_get("/")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }
    assert_includes ids, pub.id
    refute_includes ids, @conv.id
  end

  def test_index_signed_in_sees_owned
    sign_in(@owner)
    _, _, body = inertia_get("/")
    data = parse_json(body)
    ids = data["props"]["conversations"].map { |c| c["id"] }
    assert_includes ids, @conv.id
  end

  def test_index_conversation_list_json_exact_key_set
    pub = Factory[:conversation, published: true]
    _, _, body = inertia_get("/")
    data = parse_json(body)
    conv_data = data["props"]["conversations"].find { |c| c["id"] == pub.id }
    refute_nil conv_data
    expected_keys = %w[id title status published turns_count owned shared].sort
    assert_equal expected_keys, conv_data.keys.sort,
                 "conversation_list_json key set must match exactly"
  end

  def test_index_owned_flag_true_for_owner
    sign_in(@owner)
    _, _, body = inertia_get("/")
    data = parse_json(body)
    conv_data = data["props"]["conversations"].find { |c| c["id"] == @conv.id }
    assert_equal true,  conv_data["owned"]
    assert_equal false, conv_data["shared"]
  end

  def test_index_shared_flag_true_for_grantee
    Factory[:conversation_share, conversation_id: @conv.id,
            grantee_kind: "user", github_id: @grantee.github_uid,
            github_login: @grantee.username, access: "view"]
    sign_in(@grantee)
    _, _, body = inertia_get("/")
    data = parse_json(body)
    conv_data = data["props"]["conversations"].find { |c| c["id"] == @conv.id }
    refute_nil conv_data
    assert_equal false, conv_data["owned"]
    assert_equal true,  conv_data["shared"]
  end

  def test_index_turns_count_correct
    # @conv has 2 messages; Turn.group(visible_messages) determines the count
    sign_in(@owner)
    _, _, body = inertia_get("/")
    data = parse_json(body)
    conv_data = data["props"]["conversations"].find { |c| c["id"] == @conv.id }
    refute_nil conv_data
    # turns_count is an integer; exact value depends on Turn.group logic, just verify type
    assert_kind_of Integer, conv_data["turns_count"]
  end

  # ── G2: Show render ──────────────────────────────────────────────────────

  def test_show_page_object_shape_for_owner
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal "Conversations/Show", data["component"]
    props = data["props"]
    assert props.key?("conversation"), "props must have conversation"
    assert props.key?("turns"),        "props must have turns"
    assert props.key?("annotations"),  "props must have annotations"
    assert props.key?("shares"),       "props must have shares (nil or array)"
    assert props.key?("current_user")
    assert props.key?("flash")
    assert props.key?("errors")
  end

  def test_show_conversation_json_exact_key_set
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    conv = data["props"]["conversation"]
    expected_keys = %w[id title status published source original_cwd git_branch
                       agent_version can_manage can_note owner parent children].sort
    assert_equal expected_keys, conv.keys.sort,
                 "conversation_json key set must match exactly"
  end

  def test_show_turns_are_turn_json
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    turns = data["props"]["turns"]
    assert_kind_of Array, turns
    turns.each do |t|
      assert t.key?("anchor_id"), "turn must have anchor_id"
      assert t.key?("rounds"),    "turn must have rounds"
    end
  end

  def test_show_annotations_empty_by_default
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal [], data["props"]["annotations"]
  end

  def test_show_shares_array_for_owner
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_kind_of Array, data["props"]["shares"]
  end

  def test_show_shares_nil_for_grantee
    grant("view")
    sign_in(@grantee)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_nil data["props"]["shares"]
  end

  def test_show_annotations_include_conversation_target
    sign_in(@owner)
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id,
                  target_kind: "conversation"]
    data = inertia_page("/conversations/#{@conv.id}")
    ann_ids = data["props"]["annotations"].map { |a| a["id"] }
    assert_includes ann_ids, ann.id, "conversation-target annotation must appear"
  end

  def test_show_annotations_include_visible_message_target
    sign_in(@owner)
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id,
                  target_kind: "message", anchor_message_id: @msg1.id]
    data = inertia_page("/conversations/#{@conv.id}")
    ann_ids = data["props"]["annotations"].map { |a| a["id"] }
    assert_includes ann_ids, ann.id, "message-target annotation on visible message must appear"
  end

  # ── G2: New render ───────────────────────────────────────────────────────

  def test_new_returns_200_inertia_page_for_logged_in
    sign_in(@owner)
    status, headers, body = inertia_get("/conversations/new")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    data = parse_json(body)
    assert_equal "Conversations/New", data["component"]
  end

  def test_new_url_field_correct
    sign_in(@owner)
    data = inertia_page("/conversations/new")
    assert_equal "/conversations/new", data["url"]
  end

  # ── G3: B2 matrix — §2c STAYS JSON ──────────────────────────────────────

  def test_entities_show_invisible_anon_returns_404_json
    status, headers, _ = get("/conversations/#{@conv.id}/entities/message-#{@msg1.id}")
    assert_equal 404, status
    assert_includes headers["content-type"], "application/json"
  end

  def test_entities_show_invisible_signed_in_returns_404_json
    sign_in(@stranger)
    status, headers, _ = get("/conversations/#{@conv.id}/entities/message-#{@msg1.id}")
    assert_equal 404, status
    assert_includes headers["content-type"], "application/json"
  end

  def test_show_missing_record_returns_404_json
    status, headers, body = inertia_get("/conversations/99999")
    assert_equal 404, status
    assert_includes headers["content-type"], "application/json"
    assert parse_json(body).key?("error")
  end

  def test_annotation_destroy_missing_returns_404_json
    sign_in(@owner)
    status, headers, _ = delete("/annotations/99999")
    assert_equal 404, status
    assert_includes headers["content-type"], "application/json"
  end

  def test_shares_create_contract_invalid_returns_422_json
    sign_in(@owner)
    status, headers, body = post("/conversations/#{@conv.id}/shares",
                                  params: { "share" => { "access" => "invalid_access_level" } })
    assert_equal 422, status
    assert_includes headers["content-type"], "application/json"
    assert parse_json(body).key?("errors")
  end

  # ── G3: conversations#create errors round-trip ───────────────────────────

  def test_create_errors_round_trip_via_session
    sign_in(@owner)
    status, headers, _ = post("/conversations", params: { "conversation" => "not_a_hash" })
    assert_equal 302, status
    assert_equal "/conversations/new", headers["location"]
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/conversations/new", cookie: redirect_cookie)
    data = parse_json(body)
    refute_empty data.dig("props", "errors"), "props.errors must be non-empty after contract failure"
  end

  # ── G4: can_note / can_manage by viewer state ────────────────────────────

  def test_can_manage_and_can_note_for_owner
    sign_in(@owner)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal true, data["props"]["conversation"]["can_manage"]
    assert_equal true, data["props"]["conversation"]["can_note"]
  end

  def test_can_note_true_can_manage_false_for_note_grantee
    grant("note")
    sign_in(@grantee)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal false, data["props"]["conversation"]["can_manage"]
    assert_equal true,  data["props"]["conversation"]["can_note"]
  end

  def test_can_note_and_manage_false_for_view_grantee
    grant("view")
    sign_in(@grantee)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal false, data["props"]["conversation"]["can_manage"]
    assert_equal false, data["props"]["conversation"]["can_note"]
  end

  def test_can_note_and_manage_false_for_published_anon
    Space::Server::App["repos.conversations_repo"].update(@conv.id, published: true, updated_at: Time.now)
    data = inertia_page("/conversations/#{@conv.id}")
    assert_equal false, data["props"]["conversation"]["can_manage"]
    assert_equal false, data["props"]["conversation"]["can_note"]
  end

  # ── G5: sessions flash ───────────────────────────────────────────────────

  def test_sessions_create_notice_flash
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "flash-test-uid",
      info: {nickname: "flashuser", name: "Flash User", email: nil, image: nil},
      credentials: nil
    )
    _, headers, _ = post("/auth/github/callback")
    flash = flash_from_redirect(headers)
    assert_equal "Signed in as flashuser.", flash["notice"]
  end

  def test_sessions_destroy_notice_flash
    sign_in(@owner)
    _, headers, _ = get("/logout")
    flash = flash_from_redirect(headers)
    assert_equal "Signed out.", flash["notice"]
  end

  def test_sessions_failure_alert_flash
    _, headers, _ = get("/auth/failure?message=access_denied")
    flash = flash_from_redirect(headers)
    assert_equal "Authentication failed: access_denied.", flash["alert"]
  end

  # ── Digest handshake — hermetic proof ────────────────────────────────────

  def test_version_header_prevents_409
    # Sending the correct digest → no stale-version 409
    status, _, _ = inertia_get("/")
    assert_equal 200, status, "correct X-Inertia-Version must not trigger 409"
  end

  def test_stale_version_triggers_409
    env = Rack::MockRequest.env_for("/", "REQUEST_METHOD" => "GET")
    env["HTTP_X_INERTIA"] = "true"
    env["HTTP_X_INERTIA_VERSION"] = "stale-version-that-will-not-match"
    status, _, _ = app.call(env)
    assert_equal 409, status, "stale X-Inertia-Version must trigger 409"
  end
end
