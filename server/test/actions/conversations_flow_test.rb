# frozen_string_literal: true

require_relative "action_test_helper"

# Integration-flow parity for test/integration/conversations_flow_test.rb.
# Covers the two behaviors not fully asserted by per-action tests:
#   - turns_count in the index is the number of real turns, not raw messages
#   - show action nests rounds under turns and ships annotations flat
class ConversationsFlowTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @owner = Factory[:user, github_uid: "flow-conv-owner", username: "flow-conv-owner"]
    @conv  = Factory[:conversation, user_id: @owner.id, published: false]

    # Three messages: prompt opens a turn; assistant + tool_result ride in one round.
    # Turn.group produces 1 turn from 3 messages — the key assertion below.
    @prompt = Factory[:message, conversation_id: @conv.id, role: "user",
                      content: [{"type" => "text", "text" => "q"}], position: 1]
    @assistant = Factory[:message, conversation_id: @conv.id, role: "assistant",
                         content: [{"type" => "text", "text" => "a"}], position: 2]
    @result = Factory[:message, conversation_id: @conv.id, role: "user",
                      content: [{"type" => "tool_result", "tool_use_id" => "t0", "content" => "ok"}],
                      position: 3]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # Mirror of oracle: "index counts real turns, not raw messages"
  # Turn.group(3 messages) → 1 turn. The index must report turns_count: 1, not 3.
  def test_index_counts_real_turns_not_raw_messages
    sign_in(@owner)
    _, _, body = inertia_get("/")
    data      = parse_json(body)
    conv_data = data["props"]["conversations"].find { |c| c["id"] == @conv.id }
    refute_nil conv_data, "owner must see their own conversation in the index"

    raw_count   = 3  # @prompt, @assistant, @result
    turns_count = conv_data["turns_count"]
    assert_equal 1, turns_count,
      "turns_count must equal Turn.group result (1 turn), not raw message count"
    assert_operator turns_count, :<, raw_count,
      "turns_count must be less than raw message count (#{raw_count})"
  end

  # Mirror of oracle: "show nests rounds under turns and ships annotations flat"
  # Verifies: prompt id in turn, round anchor, round messages, and annotation in flat list.
  def test_show_nests_rounds_under_turns_and_ships_annotations_flat
    sign_in(@owner)

    # Create a round-level annotation via factory (bypasses the create action —
    # this test targets show, not create).
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id,
                  body: "the pivot", target_kind: "round",
                  anchor_message_id: @assistant.id]

    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data       = parse_json(body)

    turn = data["props"]["turns"].first
    refute_nil turn, "owner must see at least one turn"

    assert_equal @prompt.id, turn["prompt"]["id"],
      "turn prompt must be @prompt"
    assert_equal [@assistant.id], turn["rounds"].map { |r| r["anchor_id"] },
      "round anchor must be @assistant (first structural non-prompt member)"
    all_message_ids = turn["rounds"].flat_map { |r| r["messages"].map { |m| m["id"] } }
    assert_includes all_message_ids, @assistant.id, "@assistant must be in a round"
    assert_includes all_message_ids, @result.id,    "@result must ride along in the same round"

    refute turn["prompt"].key?("annotations"),
      "annotations must not nest under messages (they ship flat)"

    ann_data = data["props"]["annotations"].find { |a| a["id"] == ann.id }
    refute_nil ann_data, "annotation must appear in the flat annotations list"
    assert_equal "round",       ann_data["target_kind"]
    assert_equal @assistant.id, ann_data["anchor_message_id"]
    assert_equal true,          ann_data["can_delete"], "owner must be able to delete their own annotation"
  end
end
