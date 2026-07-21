# frozen_string_literal: true

require "delegate"
require_relative "support"

S = Space::Server::Serializers::Conversation

# TestConversation (support.rb) predates turns_count becoming a real column
# read directly by conversation_list_json. Wrap it with SimpleDelegator to add
# turns_count per-test without touching the shared double.
class TestConversationWithTurns < SimpleDelegator
  def initialize(base, turns_count)
    super(base)
    @turns_count = turns_count
  end

  def turns_count = @turns_count
end

class ConversationListJsonTest < Minitest::Test
  EXPECTED_KEYS = %i[id title status published turns_count owned shared].freeze

  def owner     = TestUser.new(id: 1, username: "alice", name: "Alice", avatar_url: "http://a.example")
  def viewer    = TestUser.new(id: 2, username: "bob",   name: "Bob",   avatar_url: "http://b.example")
  def conv(title: "My conv", turns_count: 0)
    base = TestConversation.new(
      id: 42, title: title, status: :completed, published: false,
      source: nil, original_cwd: nil, git_branch: nil, agent_version: nil,
      user: owner, owner_id: 1, view_grantee_ids: [2], note_grantee_ids: []
    )
    TestConversationWithTurns.new(base, turns_count)
  end

  def test_exact_key_set
    result = S.conversation_list_json(conv(turns_count: 3), viewer: owner)
    assert_equal EXPECTED_KEYS.sort, result.keys.sort
  end

  def test_owner_flags
    result = S.conversation_list_json(conv(turns_count: 5), viewer: owner)
    assert_equal true,  result[:owned]
    assert_equal false, result[:shared]
    assert_equal 5,     result[:turns_count]
  end

  def test_view_shared_non_owner_flags
    result = S.conversation_list_json(conv, viewer: viewer)
    assert_equal false, result[:owned]
    assert_equal true,  result[:shared]
  end

  def test_anon_flags
    result = S.conversation_list_json(conv, viewer: nil)
    assert_equal false, result[:owned]
    assert_equal false, result[:shared]
  end

  def test_non_owner_non_shared_flags
    stranger = TestUser.new(id: 99, username: "z", name: nil, avatar_url: nil)
    result = S.conversation_list_json(conv, viewer: stranger)
    assert_equal false, result[:owned]
    assert_equal false, result[:shared]
  end

  def test_display_title_present
    result = S.conversation_list_json(conv(title: "Real title"), viewer: nil)
    assert_equal "Real title", result[:title]
  end

  def test_display_title_nil_falls_back
    result = S.conversation_list_json(conv(title: nil), viewer: nil)
    assert_equal "Untitled conversation", result[:title]
  end

  def test_display_title_blank_falls_back
    result = S.conversation_list_json(conv(title: "  "), viewer: nil)
    assert_equal "Untitled conversation", result[:title]
  end
end

class ConversationJsonTest < Minitest::Test
  EXPECTED_KEYS = %i[
    id title status published source original_cwd git_branch agent_version
    can_manage can_note owner
  ].freeze
  OWNER_KEYS = %i[username name avatar_url].freeze

  def owner_user = TestUser.new(id: 1, username: "alice", name: "Alice A", avatar_url: "http://a.example")
  def viewer     = TestUser.new(id: 2, username: "bob",   name: "Bob",     avatar_url: "http://b.example")
  def note_viewer = TestUser.new(id: 3, username: "carol", name: "Carol",  avatar_url: "http://c.example")

  def conv
    TestConversation.new(
      id: 7, title: "Chat", status: :completed, published: false,
      source: "claude", original_cwd: "/tmp", git_branch: "main", agent_version: "1.0",
      user: owner_user, owner_id: 1, view_grantee_ids: [2], note_grantee_ids: [3]
    )
  end

  def test_exact_key_set
    result = S.conversation_json(conv, viewer: owner_user, owner: true)
    assert_equal EXPECTED_KEYS.sort, result.keys.sort
  end

  def test_owner_sub_hash_keys
    result = S.conversation_json(conv, viewer: owner_user, owner: true)
    assert_equal OWNER_KEYS.sort, result[:owner].keys.sort
  end

  def test_owner_can_manage_and_can_note
    result = S.conversation_json(conv, viewer: owner_user, owner: true)
    assert_equal true, result[:can_manage]
    assert_equal true, result[:can_note]
  end

  def test_view_shared_no_manage_no_note
    result = S.conversation_json(conv, viewer: viewer, owner: false)
    assert_equal false, result[:can_manage]
    assert_equal false, result[:can_note]
  end

  def test_note_grantee_no_manage_but_can_note
    result = S.conversation_json(conv, viewer: note_viewer, owner: false)
    assert_equal false, result[:can_manage]
    assert_equal true,  result[:can_note]
  end

  def test_anon_no_manage_no_note
    result = S.conversation_json(conv, viewer: nil, owner: false)
    assert_equal false, result[:can_manage]
    assert_equal false, result[:can_note]
  end

  def test_owner_sub_hash_values
    result = S.conversation_json(conv, viewer: owner_user, owner: true)
    assert_equal "alice",          result[:owner][:username]
    assert_equal "Alice A",        result[:owner][:name]
    assert_equal "http://a.example", result[:owner][:avatar_url]
  end

  def test_scalar_attrs_pass_through
    result = S.conversation_json(conv, viewer: owner_user, owner: true)
    assert_equal "claude", result[:source]
    assert_equal "/tmp",   result[:original_cwd]
    assert_equal "main",   result[:git_branch]
    assert_equal "1.0",    result[:agent_version]
  end
end

class ShareJsonTest < Minitest::Test
  EXPECTED_KEYS = %i[id grantee_kind github_login access avatar_url].freeze

  def share
    TestShare.new(id: 5, grantee_kind: "user", github_login: "bob",
                  access: "view", github_id: "99")
  end

  def test_exact_key_set
    assert_equal EXPECTED_KEYS.sort, S.share_json(share).keys.sort
  end

  def test_avatar_url_uses_github_id
    result = S.share_json(share)
    assert_equal "https://avatars.githubusercontent.com/u/99", result[:avatar_url]
  end

  def test_other_fields_pass_through
    result = S.share_json(share)
    assert_equal 5,      result[:id]
    assert_equal "user", result[:grantee_kind]
    assert_equal "bob",  result[:github_login]
    assert_equal "view", result[:access]
  end
end

class TurnJsonTest < Minitest::Test
  EXPECTED_KEYS   = %i[anchor_id prompt rounds].freeze
  ROUND_KEYS      = %i[anchor_id messages].freeze
  MSG_KEYS        = %i[id role model position published blocks can_publish].freeze

  def msg(id)
    TestMsg.new(id: id, role: "assistant", model: "claude", position: id,
                published: false, blocks: [{ "type" => "text", "text" => "hi" }])
  end

  def test_exact_top_level_key_set
    round = TestRound.new(anchor_id: 2, messages: [msg(2)])
    prompt_msg = msg(1)
    turn = TestTurn.new(anchor_id: 1, prompt: prompt_msg, rounds: [round])
    result = S.turn_json(turn, owner: true)
    assert_equal EXPECTED_KEYS.sort, result.keys.sort
  end

  def test_round_key_set
    round = TestRound.new(anchor_id: 2, messages: [msg(2)])
    turn  = TestTurn.new(anchor_id: 1, prompt: msg(1), rounds: [round])
    result = S.turn_json(turn, owner: false)
    assert_equal ROUND_KEYS.sort, result[:rounds].first.keys.sort
  end

  def test_message_inside_round_key_set
    round = TestRound.new(anchor_id: 2, messages: [msg(2)])
    turn  = TestTurn.new(anchor_id: 1, prompt: msg(1), rounds: [round])
    result = S.turn_json(turn, owner: false)
    assert_equal MSG_KEYS.sort, result[:rounds].first[:messages].first.keys.sort
  end

  def test_preamble_turn_prompt_is_nil
    round = TestRound.new(anchor_id: 1, messages: [msg(1)])
    turn  = TestTurn.new(anchor_id: 1, prompt: nil, rounds: [round])
    result = S.turn_json(turn, owner: false)
    assert_nil result[:prompt]
  end

  def test_prompt_serialized_when_present
    prompt_msg = msg(1)
    turn = TestTurn.new(anchor_id: 1, prompt: prompt_msg, rounds: [])
    result = S.turn_json(turn, owner: true)
    assert_equal MSG_KEYS.sort, result[:prompt].keys.sort
    assert_equal 1, result[:prompt][:id]
  end

  def test_rounds_list
    r1 = TestRound.new(anchor_id: 2, messages: [msg(2)])
    r2 = TestRound.new(anchor_id: 3, messages: [msg(3)])
    turn = TestTurn.new(anchor_id: 1, prompt: nil, rounds: [r1, r2])
    result = S.turn_json(turn, owner: false)
    assert_equal 2,  result[:rounds].length
    assert_equal [2, 3], result[:rounds].map { |r| r[:anchor_id] }
  end

  def test_owner_threads_to_message_can_publish
    round = TestRound.new(anchor_id: 2, messages: [msg(2)])
    turn  = TestTurn.new(anchor_id: 1, prompt: msg(1), rounds: [round])
    owner_result = S.turn_json(turn, owner: true)
    guest_result = S.turn_json(turn, owner: false)
    assert_equal true,  owner_result[:rounds].first[:messages].first[:can_publish]
    assert_equal false, guest_result[:rounds].first[:messages].first[:can_publish]
  end
end

class MessageJsonTest < Minitest::Test
  EXPECTED_KEYS = %i[id role model position published blocks can_publish].freeze

  def msg(blocks: [{ "type" => "text", "text" => "hello" }], model: "claude-4")
    TestMsg.new(id: 10, role: "assistant", model: model, position: 3,
                published: false, blocks: blocks)
  end

  def test_exact_key_set
    assert_equal EXPECTED_KEYS.sort, S.message_json(msg, owner: false).keys.sort
  end

  def test_blocks_pass_through_unchanged
    blocks = [{ "type" => "tool_use", "name" => "Bash", "id" => "t1", "input" => {} }]
    result = S.message_json(msg(blocks: blocks), owner: false)
    assert_equal blocks, result[:blocks]
  end

  def test_null_model_passes_through
    result = S.message_json(msg(model: nil), owner: false)
    assert_nil result[:model]
  end

  def test_owner_true_sets_can_publish
    assert_equal true,  S.message_json(msg, owner: true)[:can_publish]
    assert_equal false, S.message_json(msg, owner: false)[:can_publish]
  end
end

class AnnotationJsonTest < Minitest::Test
  EXPECTED_KEYS = %i[
    id body author author_avatar_url can_delete
    target_kind anchor_message_id tool_use_id selector
  ].freeze

  def ann_user = TestUser.new(id: 5, username: "alice", name: "Alice", avatar_url: "http://a.example")
  def viewer   = TestUser.new(id: 5, username: "alice", name: "Alice", avatar_url: "http://a.example")
  def other    = TestUser.new(id: 9, username: "bob",   name: "Bob",   avatar_url: "http://b.example")

  def ann(user_id: 5)
    TestAnnotation.new(
      id: 20, body: "Nice point", user: ann_user, user_id: user_id,
      target_kind: "message", anchor_message_id: 42, tool_use_id: nil,
      selector: nil
    )
  end

  def test_exact_key_set
    result = S.annotation_json(ann, viewer: viewer)
    assert_equal EXPECTED_KEYS.sort, result.keys.sort
  end

  def test_can_delete_true_when_viewer_owns_annotation
    result = S.annotation_json(ann(user_id: 5), viewer: viewer)
    assert_equal true, result[:can_delete]
  end

  def test_can_delete_false_when_different_viewer
    result = S.annotation_json(ann(user_id: 5), viewer: other)
    assert_equal false, result[:can_delete]
  end

  def test_can_delete_false_when_nil_viewer
    result = S.annotation_json(ann(user_id: 5), viewer: nil)
    assert_equal false, result[:can_delete]
  end

  def test_author_from_annotation_user
    result = S.annotation_json(ann, viewer: viewer)
    assert_equal "alice",            result[:author]
    assert_equal "http://a.example", result[:author_avatar_url]
  end

  def test_target_descriptor_fields_pass_through
    result = S.annotation_json(ann, viewer: viewer)
    assert_equal "message", result[:target_kind]
    assert_equal 42,        result[:anchor_message_id]
    assert_nil              result[:tool_use_id]
    assert_nil              result[:selector]
  end

  def test_selector_hash_passes_through
    sel = { "exact" => "some text", "position" => 10, "prefix" => "pre", "suffix" => "suf" }
    ann_with_sel = TestAnnotation.new(
      id: 21, body: "X", user: ann_user, user_id: 5,
      target_kind: "message", anchor_message_id: 1, tool_use_id: nil, selector: sel
    )
    result = S.annotation_json(ann_with_sel, viewer: viewer)
    assert_equal sel, result[:selector]
  end
end
