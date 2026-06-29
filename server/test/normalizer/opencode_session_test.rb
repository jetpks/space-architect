# frozen_string_literal: true

require_relative "support"
require "space/server/normalizer/opencode_session"

class OpencodeSessionTest < Minitest::Test
  SESSION_ID  = "ses_test_01"
  SESSION_DIR = "/test/space"

  def parser
    Space::Server::Normalizer::OpencodeSession.new(session_id: SESSION_ID, session_dir: SESSION_DIR)
  end

  def msg(id:, role:, parts:, **data)
    { "id" => id, "data" => { "role" => role }.merge(data), "parts" => parts }
  end

  def text_part(text)    = { "type" => "text",      "text" => text }
  def reasoning_part(t)  = { "type" => "reasoning", "text" => t, "time" => {} }
  def step_start_part    = { "type" => "step-start" }
  def step_finish_part(reason = "stop") = { "type" => "step-finish", "reason" => reason, "tokens" => {} }
  def patch_part         = { "type" => "patch", "hash" => "abc", "files" => [] }

  def tool_part(name, call_id, input, output, status: "completed")
    { "type" => "tool", "tool" => name, "callID" => call_id,
      "state" => { "status" => status, "input" => input, "output" => output } }
  end

  # ── run_init ──────────────────────────────────────────────────────────────────

  test "run_init emitted once on first message" do
    p = parser
    m = msg(id: "msg_1", role: "user", parts: [text_part("hi")])
    e1 = p.process(m)
    e2 = p.process(m)

    inits = (e1 + e2).select { |e| e[:type] == :run_init }
    assert_equal 1, inits.length
    assert_equal SESSION_ID, inits.first[:session_id]
  end

  test "run_init uses path.root from first message data when present" do
    p = parser
    m = { "id" => "msg_1", "data" => { "role" => "assistant", "modelID" => "m", "path" => { "root" => "/from/path" } }, "parts" => [step_finish_part] }
    events = p.process(m)
    init = events.find { |e| e[:type] == :run_init }
    assert_equal "/from/path", init[:cwd]
  end

  test "run_init falls back to session_dir when no path.root" do
    p = parser
    m = msg(id: "msg_1", role: "user", parts: [text_part("hi")])
    events = p.process(m)
    init = events.find { |e| e[:type] == :run_init }
    assert_equal SESSION_DIR, init[:cwd]
  end

  # ── assistant message ─────────────────────────────────────────────────────────

  test "assistant: message_start has correct model and role" do
    p = parser
    parts = [step_start_part, text_part("hello"), step_finish_part]
    m = msg(id: "msg_a1", role: "assistant", parts: parts,
            "modelID" => "claude-sonnet-4-6", "tokens" => { "total" => 10 })
    events = p.process(m)

    start = events.find { |e| e[:type] == :message_start }
    refute_nil start
    assert_equal "claude-sonnet-4-6", start[:model]
    assert_equal "assistant",         start[:role]
    assert_equal "msg_a1",            start[:message_id]
  end

  test "assistant: text part → block_open(:text) + text_delta + block_close" do
    p = parser
    m = msg(id: "msg_a2", role: "assistant", parts: [text_part("look at this"), step_finish_part],
            "modelID" => "m")
    events = p.process(m)

    types = events.map { |e| e[:type] }
    assert_includes types, :block_open
    assert_includes types, :text_delta
    assert_includes types, :block_close

    open  = events.find { |e| e[:type] == :block_open }
    delta = events.find { |e| e[:type] == :text_delta }
    assert_equal :text,          open[:block_type]
    assert_equal "look at this", delta[:text]
  end

  test "assistant: reasoning part → block_open(:thinking) + text_delta + block_close" do
    p = parser
    m = msg(id: "msg_a3", role: "assistant", parts: [reasoning_part("deep thought"), step_finish_part],
            "modelID" => "m")
    events = p.process(m)

    open  = events.find { |e| e[:type] == :block_open }
    delta = events.find { |e| e[:type] == :text_delta }
    assert_equal :thinking,    open[:block_type]
    assert_equal "deep thought", delta[:text]
  end

  test "assistant: tool part → block_open(:tool_use) + tool_args_delta + block_close + tool_result" do
    p = parser
    tp = tool_part("Read", "call_001", { "path" => "/foo.rb" }, "file content")
    m  = msg(id: "msg_a4", role: "assistant", parts: [tp, step_finish_part], "modelID" => "m")
    events = p.process(m)

    types = events.map { |e| e[:type] }
    assert_includes types, :block_open
    assert_includes types, :tool_args_delta
    assert_includes types, :block_close
    assert_includes types, :tool_result

    open   = events.find { |e| e[:type] == :block_open }
    delta  = events.find { |e| e[:type] == :tool_args_delta }
    result = events.find { |e| e[:type] == :tool_result }

    assert_equal :tool_use,   open[:block_type]
    assert_equal "Read",      open[:name]
    assert_equal "call_001",  open[:tool_use_id]

    parsed = JSON.parse(delta[:partial_json])
    assert_equal "/foo.rb", parsed["path"]

    assert_equal "call_001",     result[:tool_use_id]
    assert_equal "file content", result[:content]
    assert_equal false,          result[:is_error]
  end

  test "assistant: tool part with status error → is_error true" do
    p = parser
    tp = tool_part("Write", "call_002", { "path" => "/ro.rb" }, nil, status: "error")
    m  = msg(id: "msg_a5", role: "assistant", parts: [tp, step_finish_part], "modelID" => "m")
    events = p.process(m)

    result = events.find { |e| e[:type] == :tool_result }
    refute_nil result
    assert_equal true,       result[:is_error]
    assert_equal "call_002", result[:tool_use_id]
    assert_equal "",         result[:content]
  end

  test "assistant: step-start emits no events" do
    p = parser
    parts = [step_start_part, text_part("hi"), step_finish_part]
    m = msg(id: "msg_a6", role: "assistant", parts: parts, "modelID" => "m")
    events = p.process(m)

    opens = events.select { |e| e[:type] == :block_open }
    assert_equal 1, opens.length, "only text block, not step-start"
    assert_equal :text, opens.first[:block_type]
  end

  test "assistant: step-finish emits no block events but sets stop_reason on message_complete" do
    p = parser
    m = msg(id: "msg_a7", role: "assistant", parts: [step_finish_part("tool-calls")], "modelID" => "m")
    events = p.process(m)

    complete = events.find { |e| e[:type] == :message_complete }
    refute_nil complete
    assert_equal :tool_use, complete[:stop_reason]
  end

  test "assistant: patch part emits no events" do
    p = parser
    m = msg(id: "msg_a8", role: "assistant", parts: [patch_part, text_part("x"), step_finish_part],
            "modelID" => "m")
    events = p.process(m)

    opens = events.select { |e| e[:type] == :block_open }
    assert_equal 1, opens.length
  end

  test "assistant: unknown part type emits no events" do
    p = parser
    unknown = { "type" => "future-thing", "data" => "whatever" }
    m = msg(id: "msg_a9", role: "assistant", parts: [unknown, text_part("ok"), step_finish_part],
            "modelID" => "m")
    events = p.process(m)

    opens = events.select { |e| e[:type] == :block_open }
    assert_equal 1, opens.length
  end

  test "assistant: message_complete with stop_reason end_turn when no step-finish" do
    p = parser
    m = msg(id: "msg_aa", role: "assistant", parts: [text_part("done")], "modelID" => "m")
    events = p.process(m)

    complete = events.find { |e| e[:type] == :message_complete }
    assert_equal :end_turn, complete[:stop_reason]
  end

  test "assistant: multiple content types in one message" do
    p = parser
    tp = tool_part("Bash", "call_x", { "cmd" => "ls" }, "file1\nfile2")
    parts = [
      step_start_part,
      reasoning_part("thinking"),
      text_part("response text"),
      tp,
      step_finish_part("tool-calls")
    ]
    m = msg(id: "msg_ab", role: "assistant", parts: parts, "modelID" => "opus")
    events = p.process(m)

    types = events.map { |e| e[:type] }
    assert_includes types, :run_init
    assert_includes types, :message_start
    assert_includes types, :message_complete
    assert_includes types, :tool_result

    opens = events.select { |e| e[:type] == :block_open }
    assert_equal 3, opens.length
    assert_equal :thinking, opens[0][:block_type]
    assert_equal :text,     opens[1][:block_type]
    assert_equal :tool_use, opens[2][:block_type]
  end

  # ── user message ──────────────────────────────────────────────────────────────

  test "user: text part → role:user text message" do
    p = parser
    m = msg(id: "msg_u1", role: "user", parts: [text_part("Hello opencode")])
    events = p.process(m)

    start = events.find { |e| e[:type] == :message_start }
    refute_nil start
    assert_equal "user", start[:role]

    delta = events.find { |e| e[:type] == :text_delta }
    assert_equal "Hello opencode", delta[:text]

    complete = events.find { |e| e[:type] == :message_complete }
    assert_equal :end_turn, complete[:stop_reason]
  end

  test "user: non-text parts skipped" do
    p = parser
    m = msg(id: "msg_u2", role: "user", parts: [{ "type" => "metadata", "data" => {} }, text_part("hi")])
    events = p.process(m)
    starts = events.select { |e| e[:type] == :message_start }
    assert_equal 1, starts.length
    assert_equal "user", starts.first[:role]
  end

  test "user: no text parts → no message events" do
    p = parser
    m = msg(id: "msg_u3", role: "user", parts: [{ "type" => "metadata" }])
    events = p.process(m)
    # Only run_init is emitted (first call)
    types = events.map { |e| e[:type] }
    assert_equal [:run_init], types
  end

  # ── garbage / edge cases ──────────────────────────────────────────────────────

  test "nil data returns []" do
    p = parser
    assert_equal [], p.process({ "data" => nil, "parts" => [] })
  end

  test "non-hash data returns []" do
    p = parser
    assert_equal [], p.process({ "data" => "garbage", "parts" => [] })
  end

  test "nil part entry in parts array does not raise" do
    p = parser
    m = msg(id: "msg_g1", role: "assistant", parts: [nil, text_part("ok"), step_finish_part],
            "modelID" => "m")
    events = p.process(m)
    refute_empty events
    assert_equal :end_turn, events.last[:stop_reason]
  end

  test "all events are frozen hashes with symbol keys" do
    p = parser
    tp = tool_part("Read", "c1", {}, "out")
    parts = [step_start_part, text_part("hi"), reasoning_part("think"), tp, step_finish_part]
    m  = msg(id: "msg_g2", role: "assistant", parts: parts, "modelID" => "m")
    m2 = msg(id: "msg_g3", role: "user", parts: [text_part("hello")])

    events = p.process(m) + p.process(m2)
    refute_empty events
    events.each do |e|
      assert e.frozen?, "event #{e[:type].inspect} is not frozen"
      e.each_key { |k| assert_kind_of Symbol, k }
    end
  end

  test "block_ids are index-based strings within a message" do
    p = parser
    parts = [step_start_part, text_part("a"), reasoning_part("b"), step_finish_part]
    m = msg(id: "msg_g4", role: "assistant", parts: parts, "modelID" => "m")
    events = p.process(m)

    opens = events.select { |e| e[:type] == :block_open }
    # step-start at index 0 skipped, text at index 1, reasoning at index 2
    assert_equal "1", opens[0][:block_id]
    assert_equal "2", opens[1][:block_id]
  end
end
