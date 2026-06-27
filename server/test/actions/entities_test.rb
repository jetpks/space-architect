# frozen_string_literal: true

require_relative "action_test_helper"

# G5: entities.show — full repo→struct→Turn.group→Entity→JSON stack.
# Conversations are published so entity resolution tests work without auth.
# Visibility-gating tests live in authz_test.rb (G2/G4).
class EntitiesActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "entity-test-owner", username: "entity-owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def make_conversation_with_messages
    conv = Factory[:conversation, user_id: @owner.id, published: true]
    prompt = Factory[:message, conversation_id: conv.id, role: "user",
                     content: [{ "type" => "text", "text" => "what is 2+2?" }],
                     position: 1]
    response = Factory[:message, conversation_id: conv.id, role: "assistant",
                       content: [{ "type" => "text", "text" => "4" }],
                       position: 2]
    [conv, prompt, response]
  end

  # --- entities.show 200 with real stack ---

  def test_message_entity_returns_200_with_correct_fields
    conv, prompt, _response = make_conversation_with_messages

    status, headers, body = get("/conversations/#{conv.id}/entities/message-#{prompt.id}")
    assert_equal 200, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]

    data = parse_json(body)
    assert_equal "message-#{prompt.id}", data["address"]
    assert_equal "message", data["kind"]
    assert_equal prompt.id, data["anchor_message_id"]
    assert_nil data["tool_use_id"]
    assert_equal prompt.id, data["turn_anchor_id"]
    assert_equal "/conversations/#{conv.id}/entities/message-#{prompt.id}", data["url"]
  end

  def test_turn_entity_returns_200
    conv, prompt, _response = make_conversation_with_messages

    status, _, body = get("/conversations/#{conv.id}/entities/turn-#{prompt.id}")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal "turn-#{prompt.id}", data["address"]
    assert_equal "turn", data["kind"]
    assert_equal prompt.id, data["anchor_message_id"]
    assert_equal prompt.id, data["turn_anchor_id"]
  end

  def test_entity_data_is_sourced_from_repo_not_hardcoded
    conv, prompt, _response = make_conversation_with_messages

    _, _, body = get("/conversations/#{conv.id}/entities/message-#{prompt.id}")
    data = parse_json(body)
    assert_equal prompt.id, data["anchor_message_id"]
    assert_equal conv.id.to_s, data["url"].split("/")[2]
  end

  # --- entities.show 404 cases ---

  def test_missing_conversation_returns_404
    status, _, body = get("/conversations/99999/entities/message-1")
    assert_equal 404, status
    assert parse_json(body).key?("error")
  end

  def test_invalid_address_returns_404
    conv, _, _ = make_conversation_with_messages
    status, _, _ = get("/conversations/#{conv.id}/entities/garbage-address")
    assert_equal 404, status
  end

  def test_address_outside_conversation_returns_404
    conv, _, _ = make_conversation_with_messages
    status, _, _ = get("/conversations/#{conv.id}/entities/message-99999")
    assert_equal 404, status
  end

  def test_conversation_address_returns_200
    conv, _, _ = make_conversation_with_messages
    status, _, body = get("/conversations/#{conv.id}/entities/conversation")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal "conversation", data["address"]
    assert_equal "conversation", data["kind"]
    assert_nil data["anchor_message_id"]
    assert_nil data["turn_anchor_id"]
  end

  # --- URL field verification ---

  def test_url_field_matches_request_path
    conv, prompt, _ = make_conversation_with_messages
    _, _, body = get("/conversations/#{conv.id}/entities/message-#{prompt.id}")
    data = parse_json(body)
    assert_equal "/conversations/#{conv.id}/entities/message-#{prompt.id}", data["url"]
  end

  # --- Annotation 422 via contract (requires login from 3b) ---

  def test_annotations_create_returns_401_for_anon
    conv, _, _ = make_conversation_with_messages
    status, headers, _ = post(
      "/conversations/#{conv.id}/annotations",
      params: { "annotation" => { "anchor_message_id" => "not_a_number" } }
    )
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_annotations_create_contract_failure_redirects_back_with_alert
    conv, _, _ = make_conversation_with_messages
    sign_in(@owner)
    status, headers, _ = post(
      "/conversations/#{conv.id}/annotations",
      params: { "annotation" => { "anchor_message_id" => "not_a_number" } }
    )
    assert_equal 302, status
    flash = flash_from_redirect(headers)
    refute_nil flash["alert"], "contract failure must set alert flash"
  end

  def test_annotations_create_wrong_type_redirects_back_with_alert
    conv, _, _ = make_conversation_with_messages
    sign_in(@owner)
    status, headers, _ = post(
      "/conversations/#{conv.id}/annotations",
      params: { "annotation" => "not_a_hash" }
    )
    assert_equal 302, status
    flash = flash_from_redirect(headers)
    refute_nil flash["alert"], "contract failure must set alert flash"
  end

  def test_annotations_create_valid_params_redirects_back_with_notice
    conv, prompt, _ = make_conversation_with_messages
    sign_in(@owner)
    status, headers, _ = post(
      "/conversations/#{conv.id}/annotations",
      params: { "annotation" => { "body" => "great", "target_kind" => "message",
                                  "anchor_message_id" => prompt.id.to_s } }
    )
    assert_equal 302, status
    flash = flash_from_redirect(headers)
    assert_equal "Annotation added.", flash["notice"]
  end

  # --- Shares 422 via contract (requires owner from 3b) ---

  def test_shares_create_returns_401_for_anon
    conv, _, _ = make_conversation_with_messages
    status, headers, _ = post(
      "/conversations/#{conv.id}/shares",
      params: { "share" => { "access" => "view" } }
    )
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_shares_create_returns_422_for_owner_with_missing_fields
    conv, _, _ = make_conversation_with_messages
    sign_in(@owner)
    status, _, body = post(
      "/conversations/#{conv.id}/shares",
      params: { "share" => { "access" => "view" } }
    )
    assert_equal 422, status
    data = parse_json(body)
    assert data.key?("errors")
  end

  def test_shares_update_returns_401_for_anon
    conv, _, _ = make_conversation_with_messages
    share = Factory[:conversation_share, conversation_id: conv.id]
    status, headers, _ = inertia_patch(
      "/conversations/#{conv.id}/shares/#{share.id}",
      params: { "share" => { "access" => "" } }
    )
    assert_equal 303, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_shares_update_contract_failure_redirects_back_with_alert
    conv, _, _ = make_conversation_with_messages
    share = Factory[:conversation_share, conversation_id: conv.id]
    sign_in(@owner)
    status, headers, _ = patch(
      "/conversations/#{conv.id}/shares/#{share.id}",
      params: { "share" => { "access" => "" } }
    )
    assert_equal 302, status
    flash = flash_from_redirect(headers)
    refute_nil flash["alert"], "contract failure must set alert flash"
  end
end
