# frozen_string_literal: true

require_relative "support"

class ClaudeCodeTest < Minitest::Test
  def parser = Space::Server::Normalizer::ClaudeCode.new

  def parse_fixture(filename)
    p = parser
    File.readlines(File.join(NORMALIZER_FIXTURE_DIR, filename), chomp: true)
        .flat_map { |line| p.process(line) }
  end

  # ── text-only fixture ────────────────────────────────────────────────────────

  test "text-only stream: exact event-type sequence" do
    events = parse_fixture("claude_code_stream_text.jsonl")
    assert_equal(
      [:run_init, :message_start, :block_open, :text_delta, :text_delta,
       :block_close, :message_complete, :run_complete],
      events.map { |e| e[:type] }
    )
  end

  test "text-only stream: run_init fields" do
    events  = parse_fixture("claude_code_stream_text.jsonl")
    run_init = events.find { |e| e[:type] == :run_init }
    assert_equal "c820d3e7-db88-467a-a8ac-f274dd711d9d", run_init[:session_id]
    assert_match "claude-opus-4-8",                      run_init[:model]
    assert_equal "/home/ci/space-architect-server", run_init[:cwd]
    assert_includes run_init[:tools], "Bash"
  end

  test "text-only stream: message_start fields" do
    events    = parse_fixture("claude_code_stream_text.jsonl")
    msg_start = events.find { |e| e[:type] == :message_start }
    assert_equal "msg_01SnMAgLiUV2k4QPA5nYT3ob", msg_start[:message_id]
    assert_equal "assistant",                     msg_start[:role]
    assert_equal "claude-opus-4-8",               msg_start[:model]
  end

  test "text-only stream: block_open fields" do
    events     = parse_fixture("claude_code_stream_text.jsonl")
    block_open = events.find { |e| e[:type] == :block_open }
    assert_equal "0",   block_open[:block_id]
    assert_equal 0,     block_open[:index]
    assert_equal :text, block_open[:block_type]
    assert_nil           block_open[:name]
    assert_nil           block_open[:tool_use_id]
  end

  test "text-only stream: text deltas" do
    events = parse_fixture("claude_code_stream_text.jsonl")
    deltas = events.select { |e| e[:type] == :text_delta }
    assert_equal 2, deltas.length
    assert_equal "h", deltas[0][:text]
    assert_equal "i", deltas[1][:text]
    assert_equal "0", deltas[0][:block_id]
  end

  test "text-only stream: message_complete and run_complete" do
    events       = parse_fixture("claude_code_stream_text.jsonl")
    msg_complete = events.find { |e| e[:type] == :message_complete }
    run_complete = events.find { |e| e[:type] == :run_complete }

    assert_equal :end_turn,                        msg_complete[:stop_reason]
    assert_equal "msg_01SnMAgLiUV2k4QPA5nYT3ob", msg_complete[:message_id]

    assert_equal :end_turn, run_complete[:stop_reason]
    assert_equal 1192,      run_complete[:duration_ms]
    assert_in_delta 0.02652, run_complete[:cost_usd], 0.00001
  end

  test "text-only stream: all events are frozen hashes with symbol keys" do
    events = parse_fixture("claude_code_stream_text.jsonl")
    events.each do |e|
      assert e.frozen?, "event #{e[:type].inspect} is not frozen"
      e.each_key { |k| assert_kind_of Symbol, k, "key #{k.inspect} is not a Symbol" }
    end
  end

  # ── tool-use fixture ─────────────────────────────────────────────────────────

  test "tool-use stream: contains expected event types" do
    events = parse_fixture("claude_code_stream_tooluse.jsonl")
    types  = events.map { |e| e[:type] }
    assert_includes types, :block_open
    assert_includes types, :tool_args_delta
    assert_includes types, :block_close
    assert_includes types, :tool_result
  end

  test "tool-use stream: tool_use block_open fields" do
    events     = parse_fixture("claude_code_stream_tooluse.jsonl")
    tool_block = events.find { |e| e[:type] == :block_open && e[:block_type] == :tool_use }

    assert_equal "1",                              tool_block[:block_id]
    assert_equal 1,                                tool_block[:index]
    assert_equal :tool_use,                        tool_block[:block_type]
    assert_equal "Read",                           tool_block[:name]
    assert_equal "toolu_01YFdr4tYvmYTAfFHQz9kwdd", tool_block[:tool_use_id]
  end

  test "tool-use stream: tool_result event" do
    events      = parse_fixture("claude_code_stream_tooluse.jsonl")
    tool_result = events.find { |e| e[:type] == :tool_result }

    assert_equal "toolu_01YFdr4tYvmYTAfFHQz9kwdd", tool_result[:tool_use_id]
    assert_equal false,                              tool_result[:is_error]
    assert_includes tool_result[:content], "space-architect-server"
  end

  test "tool-use stream: first message_complete has :tool_use stop_reason" do
    events        = parse_fixture("claude_code_stream_tooluse.jsonl")
    msg_completes = events.select { |e| e[:type] == :message_complete }

    assert_equal 2, msg_completes.length
    assert_equal :tool_use, msg_completes[0][:stop_reason]
    assert_equal :end_turn, msg_completes[1][:stop_reason]
  end

  test "tool-use stream: two full message lifecycles" do
    events     = parse_fixture("claude_code_stream_tooluse.jsonl")
    msg_starts = events.select { |e| e[:type] == :message_start }

    assert_equal 2, msg_starts.length
    assert_equal "msg_018NQW9ya6fcCiLGch56SKtJ", msg_starts[0][:message_id]
    assert_equal "msg_01RyWHdrgzGr66SyJgdWhkYo", msg_starts[1][:message_id]
  end

  test "tool-use stream: tool_args_deltas accumulate tool input" do
    events = parse_fixture("claude_code_stream_tooluse.jsonl")
    deltas = events.select { |e| e[:type] == :tool_args_delta }

    accumulated = deltas.map { |e| e[:partial_json] }.join
    assert_includes accumulated, "file_path"
    assert_includes accumulated, "README.md"
  end

  # ── edge cases ───────────────────────────────────────────────────────────────

  test "empty string returns empty array" do
    assert_equal [], parser.process("")
  end

  test "blank string returns empty array" do
    assert_equal [], parser.process("   \n")
  end

  test "nil returns empty array" do
    assert_equal [], parser.process(nil)
  end

  test "unparseable JSON returns empty array" do
    assert_equal [], parser.process("{not json")
  end

  test "pre-parsed hash is accepted" do
    record = { "type" => "system", "subtype" => "init",
               "session_id" => "abc", "model" => "m", "cwd" => "/", "tools" => [] }
    events = parser.process(record)
    assert_equal 1, events.length
    assert_equal :run_init, events.first[:type]
    assert_equal "abc",     events.first[:session_id]
  end

  test "unknown line types produce no events" do
    assert_equal [], parser.process('{"type":"unknown_future_event"}')
  end

  test "rate_limit_event produces no events" do
    assert_equal [], parser.process('{"type":"rate_limit_event","rate_limit_info":{}}')
  end

  test "non-partial assistant record emits full lifecycle" do
    p      = parser  # fresh — no stream_events seen, so partial_mode = false
    record = {
      "type"    => "assistant",
      "message" => {
        "id"          => "msg_abc",
        "model"       => "claude-test",
        "role"        => "assistant",
        "content"     => [{ "type" => "text", "text" => "hello" }],
        "stop_reason" => "end_turn",
        "usage"       => { "input_tokens" => 10, "output_tokens" => 1 }
      }
    }
    events = p.process(record)
    types  = events.map { |e| e[:type] }
    assert_equal [:message_start, :block_open, :text_delta, :block_close, :message_complete], types
    assert_equal "hello",    events[2][:text]
    assert_equal :end_turn,  events[4][:stop_reason]
  end
end
