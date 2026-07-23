# frozen_string_literal: true

require_relative "../test_helper"
require "space/server/runs/persistor"

class PersistorTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :runs, :users].each { |t| conn[t].delete }
    @user              = Factory[:user]
    @conversations_repo = Space::Server::App["repos.conversations_repo"]
    @messages_repo      = Space::Server::App["repos.messages_repo"]
    @runs_repo          = Space::Server::App["repos.runs_repo"]
    @persistor          = Space::Server::Runs::Persistor.new(@conversations_repo, @messages_repo)
  end

  def test_setup_creates_conversation_owned_by_run_user
    run = Factory[:run, user_id: @user.id]
    conv = @persistor.setup(run)
    assert_equal run.user_id, conv.user_id
    assert_equal "architect_dispatch", conv.source
  end

  def test_setup_accepts_source_override
    run = Factory[:run, user_id: @user.id]
    conv = @persistor.setup(run, source: "job")
    assert_equal "job", conv.source
  end

  def test_setup_sets_conversation_id_reader
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)
    refute_nil @persistor.conversation_id
  end

  def test_message_complete_persists_text_message
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    [
      { type: :message_start,   role: "assistant", model: "test-model" },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "Hello, " },
      { type: :text_delta,      block_id: "0", text: "world!" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete, message_id: "m1", stop_reason: :end_turn }
    ].each { |e| @persistor.process(e) }

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 1, msgs.length
    msg = msgs.first
    assert_equal "assistant", msg.role
    assert_equal 0, msg.position
    assert_equal [{ "type" => "text", "text" => "Hello, world!" }], msg.blocks
  end

  def test_tool_use_block_parsed_from_json_deltas
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    [
      { type: :message_start,    role: "assistant", model: nil },
      { type: :block_open,       block_id: "0", index: 0, block_type: :tool_use, name: "Bash", tool_use_id: "tu_1" },
      { type: :tool_args_delta,  block_id: "0", partial_json: '{"command":' },
      { type: :tool_args_delta,  block_id: "0", partial_json: '"ls"}' },
      { type: :block_close,      block_id: "0" },
      { type: :message_complete, message_id: "m1", stop_reason: :tool_use }
    ].each { |e| @persistor.process(e) }

    msg = @messages_repo.for_conversation(@persistor.conversation_id).first
    block = msg.blocks.first
    assert_equal "tool_use",          block["type"]
    assert_equal "Bash",              block["name"]
    assert_equal({ "command" => "ls" }, block["input"])
  end

  def test_tool_result_event_writes_user_message
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    @persistor.process(type: :tool_result, tool_use_id: "tu_1", content: "output text", is_error: false)

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 1, msgs.length
    assert_equal "user", msgs.first.role
    block = msgs.first.blocks.first
    assert_equal "tool_result", block["type"]
    assert_equal "tu_1",        block["tool_use_id"]
    assert_equal "output text", block["content"]
  end

  def test_positions_increment_across_messages
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    # First message: assistant text
    [
      { type: :message_start,   role: "assistant", model: nil },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "step" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete }
    ].each { |e| @persistor.process(e) }

    # Second message: tool result
    @persistor.process(type: :tool_result, tool_use_id: "tu_1", content: "done", is_error: false)

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 2, msgs.length
    assert_equal 0, msgs[0].position
    assert_equal 1, msgs[1].position
  end

  def test_tool_result_interleaved_before_message_complete_preserves_order
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    # Real Claude Code fixture order: tool_result fires BEFORE message_complete for the
    # same assistant turn. The assistant message must land at position 0, tool_result at 1.
    [
      { type: :message_start,    role: "assistant", model: "m" },
      { type: :block_open,       block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,       block_id: "0", text: "using tool" },
      { type: :block_close,      block_id: "0" },
      { type: :block_open,       block_id: "1", index: 1, block_type: :tool_use, name: "Bash", tool_use_id: "tu_1" },
      { type: :tool_args_delta,  block_id: "1", partial_json: '{"cmd":"ls"}' },
      { type: :block_close,      block_id: "1" },
      { type: :tool_result,      tool_use_id: "tu_1", content: "file.rb", is_error: false },
      { type: :message_complete, message_id: "m1", stop_reason: :tool_use }
    ].each { |e| @persistor.process(e) }

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 2, msgs.size
    assert_equal "assistant", msgs[0].role, "assistant turn must precede tool_result"
    assert_equal "user",      msgs[1].role
    assert_equal 0, msgs[0].position
    assert_equal 1, msgs[1].position
    assert msgs[0].content.any? { |b| b["type"] == "tool_use" }
    assert msgs[1].content.any? { |b| b["type"] == "tool_result" }
  end

  def test_run_init_and_run_complete_events_are_ignored
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    @persistor.process(type: :run_init, session_id: "s1", model: "m", cwd: "/", tools: [])
    @persistor.process(type: :run_complete, stop_reason: :end_turn, duration_ms: 100)

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 0, msgs.length
  end

  # ── NUL scrubbing (AC4) ───────────────────────────────────────────────────────

  def test_streamed_text_is_scrubbed_of_nul_bytes
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    [
      { type: :message_start,   role: "assistant", model: "test-model" },
      { type: :block_open,      block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,      block_id: "0", text: "Hello, \0wor" },
      { type: :text_delta,      block_id: "0", text: "ld!" },
      { type: :block_close,     block_id: "0" },
      { type: :message_complete, message_id: "m1", stop_reason: :end_turn }
    ].each { |e| @persistor.process(e) }

    msg = @messages_repo.for_conversation(@persistor.conversation_id).first
    assert_equal [{ "type" => "text", "text" => "Hello, world!" }], msg.blocks
  end

  def test_tool_result_content_is_scrubbed_of_nul_bytes
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    @persistor.process(type: :tool_result, tool_use_id: "tu_1", content: "out\0put text", is_error: false)

    block = @messages_repo.for_conversation(@persistor.conversation_id).first.blocks.first
    assert_equal "output text", block["content"]
  end

  def test_full_sequence_produces_correct_db_state
    run = Factory[:run, user_id: @user.id]
    @persistor.setup(run)

    [
      { type: :run_init,         session_id: "s1", model: "test", cwd: "/", tools: [] },
      { type: :message_start,    role: "assistant", model: "test" },
      { type: :block_open,       block_id: "0", index: 0, block_type: :text },
      { type: :text_delta,       block_id: "0", text: "Checking…" },
      { type: :block_close,      block_id: "0" },
      { type: :message_complete, message_id: "m1", stop_reason: :tool_use },
      { type: :tool_result,      tool_use_id: "tu_1", content: "result", is_error: false },
      { type: :run_complete,     stop_reason: :end_turn }
    ].each { |e| @persistor.process(e) }

    msgs = @messages_repo.for_conversation(@persistor.conversation_id)
    assert_equal 2, msgs.length
    assert_equal "assistant", msgs[0].role
    assert_equal "user",      msgs[1].role
    assert_equal 0,           msgs[0].position
    assert_equal 1,           msgs[1].position
  end
end
