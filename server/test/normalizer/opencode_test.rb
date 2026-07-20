# frozen_string_literal: true

require_relative "support"

class OpencodeTest < Minitest::Test
  def parser = Space::Server::Normalizer::Opencode.new

  def parse_fixture(filename)
    p = parser
    File.readlines(File.join(NORMALIZER_FIXTURE_DIR, filename), chomp: true)
        .flat_map { |line| p.process(line) }
  end

  # ── text-only fixture ────────────────────────────────────────────────────────

  test "text-only stream: exact event-type sequence" do
    events = parse_fixture("opencode_stream_text.jsonl")
    assert_equal(
      [:message_start, :block_open, :text_delta, :block_close, :message_complete],
      events.map { |e| e[:type] }
    )
  end

  test "text-only stream: message_start fields" do
    events    = parse_fixture("opencode_stream_text.jsonl")
    msg_start = events.find { |e| e[:type] == :message_start }
    assert_equal "msg_eee5a0b910015fVptbtYlMXTbv", msg_start[:message_id]
    assert_equal "assistant",                       msg_start[:role]
  end

  test "text-only stream: block_open fields" do
    events     = parse_fixture("opencode_stream_text.jsonl")
    block_open = events.find { |e| e[:type] == :block_open }
    assert_equal "prt_eee5a14a1001Th4lBRdaO3IkYB", block_open[:block_id]
    assert_equal 0,     block_open[:index]
    assert_equal :text, block_open[:block_type]
    assert_nil           block_open[:name]
    assert_nil           block_open[:tool_use_id]
  end

  test "text-only stream: text_delta contains cat text" do
    events = parse_fixture("opencode_stream_text.jsonl")
    delta  = events.find { |e| e[:type] == :text_delta }
    assert_includes delta[:text], "Cats are"
    assert_equal "prt_eee5a14a1001Th4lBRdaO3IkYB", delta[:block_id]
  end

  test "text-only stream: message_complete with :end_turn" do
    events       = parse_fixture("opencode_stream_text.jsonl")
    msg_complete = events.find { |e| e[:type] == :message_complete }
    assert_equal :end_turn,                         msg_complete[:stop_reason]
    assert_equal "msg_eee5a0b910015fVptbtYlMXTbv", msg_complete[:message_id]
    assert_equal 8506, msg_complete[:usage]["total"]
  end

  test "text-only stream: all events are frozen hashes with symbol keys" do
    events = parse_fixture("opencode_stream_text.jsonl")
    events.each do |e|
      assert e.frozen?, "event #{e[:type].inspect} is not frozen"
      e.each_key { |k| assert_kind_of Symbol, k, "key #{k.inspect} is not a Symbol" }
    end
  end

  # ── tool-use fixture ─────────────────────────────────────────────────────────

  test "tool-use stream: event type sequence" do
    events = parse_fixture("opencode_stream_tooluse.jsonl")
    assert_equal(
      [:message_start, :block_open, :tool_args_delta, :block_close, :tool_result,
       :message_complete,
       :message_start, :block_open, :text_delta, :block_close, :message_complete],
      events.map { |e| e[:type] }
    )
  end

  test "tool-use stream: tool_use block_open fields" do
    events     = parse_fixture("opencode_stream_tooluse.jsonl")
    tool_block = events.find { |e| e[:type] == :block_open && e[:block_type] == :tool_use }

    assert_equal "prt_eee5e00ce001GpS1ibqS7Qinw4",  tool_block[:block_id]
    assert_equal 0,                                   tool_block[:index]
    assert_equal :tool_use,                           tool_block[:block_type]
    assert_equal "read",                              tool_block[:name]
    assert_equal "chatcmpl-tool-b5e0c7ffa3086c19",   tool_block[:tool_use_id]
  end

  test "tool-use stream: tool_args_delta contains serialized input" do
    events = parse_fixture("opencode_stream_tooluse.jsonl")
    delta  = events.find { |e| e[:type] == :tool_args_delta }
    parsed = JSON.parse(delta[:partial_json])
    assert_equal "/home/ci/space-architect-server/README.md",
                 parsed["filePath"]
    assert_equal 1, parsed["limit"]
  end

  test "tool-use stream: tool_result event" do
    events      = parse_fixture("opencode_stream_tooluse.jsonl")
    tool_result = events.find { |e| e[:type] == :tool_result }

    assert_equal "chatcmpl-tool-b5e0c7ffa3086c19", tool_result[:tool_use_id]
    assert_equal false,                              tool_result[:is_error]
    assert_includes tool_result[:content], "space-architect-server"
  end

  test "tool-use stream: first message_complete has :tool_use stop_reason" do
    events        = parse_fixture("opencode_stream_tooluse.jsonl")
    msg_completes = events.select { |e| e[:type] == :message_complete }

    assert_equal 2,         msg_completes.length
    assert_equal :tool_use, msg_completes[0][:stop_reason]
    assert_equal :end_turn, msg_completes[1][:stop_reason]
  end

  test "tool-use stream: two message lifecycles with correct IDs" do
    events     = parse_fixture("opencode_stream_tooluse.jsonl")
    msg_starts = events.select { |e| e[:type] == :message_start }

    assert_equal 2, msg_starts.length
    assert_equal "msg_eee5dfb3a001JDgsXhomo61JfI", msg_starts[0][:message_id]
    assert_equal "msg_eee5e085f0011xue6r4pB3oIW8", msg_starts[1][:message_id]
  end

  test "tool-use stream: block index resets between messages" do
    events      = parse_fixture("opencode_stream_tooluse.jsonl")
    block_opens = events.select { |e| e[:type] == :block_open }

    assert_equal 0, block_opens[0][:index]  # tool_use block in first message
    assert_equal 0, block_opens[1][:index]  # text block in second message (reset)
  end

  # ── edge cases ───────────────────────────────────────────────────────────────

  test "empty string returns empty array" do
    assert_equal [], parser.process("")
  end

  test "nil returns empty array" do
    assert_equal [], parser.process(nil)
  end

  test "unparseable JSON returns empty array" do
    assert_equal [], parser.process("{bad json")
  end

  test "line without part key is skipped" do
    assert_equal [], parser.process('{"type":"step_start","timestamp":1}')
  end

  test "unknown line type is skipped gracefully" do
    assert_equal [], parser.process('{"type":"unknown_future","part":{}}')
  end

  test "pre-parsed hash is accepted" do
    record = {
      "type" => "step_start",
      "part" => { "messageID" => "msg_xyz", "id" => "prt_abc", "type" => "step-start" }
    }
    events = parser.process(record)
    assert_equal 1, events.length
    assert_equal :message_start, events.first[:type]
    assert_equal "msg_xyz",      events.first[:message_id]
  end

  test "reasoning line produces thinking block" do
    step_start = { "type" => "step_start",
                   "part" => { "messageID" => "msg_r", "id" => "p1", "type" => "step-start" } }
    reasoning  = { "type" => "reasoning",
                   "part" => { "id" => "prt_r1", "messageID" => "msg_r", "text" => "let me think" } }

    p = parser
    p.process(step_start)
    events = p.process(reasoning)

    types = events.map { |e| e[:type] }
    assert_equal [:block_open, :text_delta, :block_close], types
    assert_equal :thinking,       events[0][:block_type]
    assert_equal "let me think",  events[1][:text]
  end

  test "stop_reason stop maps to :end_turn" do
    step_finish = {
      "type" => "step_finish",
      "part" => { "reason" => "stop", "messageID" => "msg_x",
                  "id" => "p1", "tokens" => {}, "type" => "step-finish" }
    }
    events = parser.process(step_finish)
    assert_equal :end_turn, events.first[:stop_reason]
  end

  test "stop_reason tool-calls maps to :tool_use" do
    step_finish = {
      "type" => "step_finish",
      "part" => { "reason" => "tool-calls", "messageID" => "msg_x",
                  "id" => "p1", "tokens" => {}, "type" => "step-finish" }
    }
    events = parser.process(step_finish)
    assert_equal :tool_use, events.first[:stop_reason]
  end

  test "complete_at_eof? is true (step_finish is message-level; no run-level sentinel)" do
    assert_equal true, parser.complete_at_eof?
  end
end
