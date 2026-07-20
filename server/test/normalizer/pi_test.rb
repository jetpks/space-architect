# frozen_string_literal: true

require_relative "support"

class PiTest < Minitest::Test
  def parser = Space::Server::Normalizer::Pi.new

  def parse_fixture(filename)
    p = parser
    File.readlines(File.join(NORMALIZER_FIXTURE_DIR, filename), chomp: true)
        .flat_map { |line| p.process(line) }
  end

  # ── pi_streaming_session.jsonl (genuine --mode json lifecycle shape) ──────

  test "streaming session: exact event-type sequence" do
    events = parse_fixture("pi_streaming_session.jsonl")
    assert_equal(
      [:run_init,
       :message_start, :block_open, :text_delta, :block_close,
       :block_open, :text_delta, :block_close,
       :block_open, :tool_args_delta, :block_close,
       :message_complete,
       :tool_result,
       :message_start, :block_open, :text_delta, :block_close, :message_complete],
      events.map { |e| e[:type] }
    )
  end

  test "streaming session: run_init fields from the session header" do
    events   = parse_fixture("pi_streaming_session.jsonl")
    run_init = events.find { |e| e[:type] == :run_init }
    assert_equal "pi-stream-1",                run_init[:session_id]
    assert_equal "/tmp/pi-stream-project",     run_init[:cwd]
  end

  test "streaming session: message_start fields from message_end" do
    events    = parse_fixture("pi_streaming_session.jsonl")
    msg_start = events.find { |e| e[:type] == :message_start }
    assert_equal "assistant",             msg_start[:role]
    assert_equal "minimax/minimax-m3",    msg_start[:model]
  end

  test "streaming session: thinking, text, and tool_use blocks in order across both assistant message_ends" do
    events      = parse_fixture("pi_streaming_session.jsonl")
    block_opens = events.select { |e| e[:type] == :block_open }
    assert_equal [:thinking, :text, :tool_use, :text], block_opens.map { |e| e[:block_type] }

    tool_block = block_opens.find { |e| e[:block_type] == :tool_use }
    assert_equal "read",          tool_block[:name]
    assert_equal "call_stream_1", tool_block[:tool_use_id]
  end

  test "streaming session: text deltas carry block text" do
    events = parse_fixture("pi_streaming_session.jsonl")
    deltas = events.select { |e| e[:type] == :text_delta }
    assert_equal "I'll write a smoke test for the importer next.", deltas[0][:text]
    assert_equal "Let me check the existing test patterns.",       deltas[1][:text]
  end

  test "streaming session: tool_args_delta carries serialized arguments" do
    events = parse_fixture("pi_streaming_session.jsonl")
    delta  = events.find { |e| e[:type] == :tool_args_delta }
    parsed = JSON.parse(delta[:partial_json])
    assert_equal "/tmp/pi-stream-project/test/services/pi_importer_test.rb", parsed["file_path"]
  end

  test "streaming session: message_complete normalizes camelCase toolUse stop reason" do
    events       = parse_fixture("pi_streaming_session.jsonl")
    msg_complete = events.find { |e| e[:type] == :message_complete }
    assert_equal :tool_use, msg_complete[:stop_reason]
  end

  test "streaming session: tool_result sourced from tool_execution_end" do
    events      = parse_fixture("pi_streaming_session.jsonl")
    tool_result = events.find { |e| e[:type] == :tool_result }
    assert_equal "call_stream_1",       tool_result[:tool_use_id]
    assert_equal false,                 tool_result[:is_error]
    assert_equal "require \"test_helper\"", tool_result[:content]
  end

  test "streaming session: message_end role toolResult produces no duplicate tool_result" do
    events = parse_fixture("pi_streaming_session.jsonl")
    assert_equal 1, events.count { |e| e[:type] == :tool_result }, "message_end(role: toolResult) must not double-emit"
  end

  test "user role message_end produces no event (the initial prompt is already known to the caller)" do
    assert_equal [], parser.process({ "type" => "message_end", "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] } })
  end

  test "streaming session: final assistant message_end (no preceding message_start) still emits its content" do
    events = parse_fixture("pi_streaming_session.jsonl")
    texts  = events.select { |e| e[:type] == :text_delta }.map { |e| e[:text] }
    assert_includes texts, "Done. I added a smoke test that asserts the importer creates at least one message and assigns the prompt title."
  end

  test "streaming session: all events are frozen hashes with symbol keys" do
    events = parse_fixture("pi_streaming_session.jsonl")
    events.each do |e|
      assert e.frozen?, "event #{e[:type].inspect} is not frozen"
      e.each_key { |k| assert_kind_of Symbol, k, "key #{k.inspect} is not a Symbol" }
    end
  end

  # ── pi_streaming_with_nul.jsonl (NUL bytes embedded in tool output) ───────

  test "streaming with NUL bytes: tool_result content survives NUL bytes intact" do
    events      = parse_fixture("pi_streaming_with_nul.jsonl")
    tool_result = events.find { |e| e[:type] == :tool_result }
    assert_includes tool_result[:content], "\u0000"
    assert_includes tool_result[:content], "Terminates the service"
  end

  test "streaming with NUL bytes: does not raise and completes the lifecycle" do
    events = parse_fixture("pi_streaming_with_nul.jsonl")
    assert_includes events.map { |e| e[:type] }, :message_complete
  end

  # ── pi_session.jsonl (tree-format session log — NOT a live stream capture) ─
  # Only the first line ("session") is byte-shaped like the live --mode json
  # probe; the remaining entries (model_change, thinking_level_change, message
  # with id/parentId) are the tree-format session log the importer reads, and
  # are gracefully ignored here rather than misinterpreted as lifecycle events.

  test "tree-format session log: only the header produces an event" do
    events = parse_fixture("pi_session.jsonl")
    assert_equal [:run_init], events.map { |e| e[:type] }
  end

  test "tree-format session log: header still yields run_init fields" do
    events   = parse_fixture("pi_session.jsonl")
    run_init = events.first
    assert_equal "pi-sess-1",        run_init[:session_id]
    assert_equal "/tmp/pi-project",  run_init[:cwd]
  end

  # ── direct record tests: agent_end / agent_settled dedupe ─────────────────
  # Neither fixture contains these types (both hand-authored fixtures stop at
  # turn_end); exercised directly per GROUNDS FACTS' documented shape.

  test "agent_end does not double-emit already-streamed message content" do
    p = parser
    p.process({ "type" => "message_end", "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "hi" }], "stopReason" => "stop" } })
    events = p.process({
      "type" => "agent_end",
      "willRetry" => false,
      "messages" => [{ "role" => "assistant", "content" => [{ "type" => "text", "text" => "hi" }] }]
    })
    assert_equal [], events
  end

  test "agent_settled produces no event" do
    assert_equal [], parser.process({ "type" => "agent_settled" })
  end

  test "turn_end does not double-emit the message it replays" do
    assert_equal [], parser.process({
      "type" => "turn_end",
      "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => "hi" }] },
      "toolResults" => []
    })
  end

  test "agent_start and turn_start produce no events" do
    assert_equal [], parser.process({ "type" => "agent_start" })
    assert_equal [], parser.process({ "type" => "turn_start" })
  end

  test "complete_at_eof? is true (no run_complete-style sentinel in the pi protocol)" do
    assert_equal true, parser.complete_at_eof?
  end

  # ── edge cases ─────────────────────────────────────────────────────────────

  test "empty string returns empty array" do
    assert_equal [], parser.process("")
  end

  test "nil returns empty array" do
    assert_equal [], parser.process(nil)
  end

  test "unparseable JSON returns empty array" do
    assert_equal [], parser.process("{not json")
  end

  test "pre-parsed hash is accepted" do
    record = { "type" => "session", "version" => 3, "id" => "abc", "cwd" => "/tmp" }
    events = parser.process(record)
    assert_equal 1, events.length
    assert_equal :run_init, events.first[:type]
  end

  test "unknown line types produce no events" do
    assert_equal [], parser.process('{"type":"unknown_future_event"}')
  end
end
