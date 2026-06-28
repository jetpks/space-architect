# frozen_string_literal: true

require_relative "support"

class ClaudeSessionTest < Minitest::Test
  FIXTURE = File.join(NORMALIZER_FIXTURE_DIR, "claude_session_fixture.jsonl")

  def parser = Space::Server::Normalizer::ClaudeSession.new

  def parse_fixture
    p = parser
    File.readlines(FIXTURE, chomp: true).flat_map { |line| p.process(line) }
  end

  # ── fixture sequence ──────────────────────────────────────────────────────────

  test "fixture: run_init emitted once on first record with sessionId+cwd" do
    events = parse_fixture
    inits = events.select { |e| e[:type] == :run_init }
    assert_equal 1, inits.length
    assert_equal "aabbccdd-1111-2222-3333-444455556666", inits.first[:session_id]
    assert_equal "/Users/eric/architect/spaces/test-space", inits.first[:cwd]
  end

  test "fixture: mode and bridge-session records produce no events" do
    p = parser
    lines = File.readlines(FIXTURE, chomp: true)
    assert_equal [], p.process(lines[0])  # mode
    assert_equal [], p.process(lines[1])  # bridge-session
  end

  test "fixture: user string prompt yields role:user text message" do
    p     = parser
    lines = File.readlines(FIXTURE, chomp: true)
    events = lines.flat_map { |l| p.process(l) }
    # First user message (non-sidechain string prompt at line 2)
    start = events.find { |e| e[:type] == :message_start && e[:role] == "user" }
    refute_nil start
    assert_equal "user", start[:role]

    delta = events.find { |e| e[:type] == :text_delta && e[:block_id] == "0" }
    refute_nil delta
    assert_includes delta[:text], "What does the space importer do?"
  end

  test "fixture: assistant thinking record yields message_start+block_open+text_delta+block_close+message_complete" do
    p      = parser
    lines  = File.readlines(FIXTURE, chomp: true)
    # parse just the thinking assistant line (index 3)
    events = p.process(lines[0])  # mode — seeds nothing, no cwd
    events = p.process(lines[2])  # user — gets run_init + user message
    events = p.process(lines[3])  # thinking assistant

    types = events.map { |e| e[:type] }
    assert_equal [:message_start, :block_open, :text_delta, :block_close, :message_complete], types
    assert_equal "assistant",          events[0][:role]
    assert_equal "msg_fixture_001",    events[0][:message_id]
    assert_equal :thinking,            events[1][:block_type]
    assert_includes events[2][:text],  "think"
    assert_equal :tool_use,            events[4][:stop_reason]
  end

  test "fixture: assistant text record yields message_start+block_open(text)+text_delta+block_close+message_complete" do
    p      = parser
    lines  = File.readlines(FIXTURE, chomp: true)
    lines.first(4).each { |l| p.process(l) }
    events = p.process(lines[4])  # text assistant

    types = events.map { |e| e[:type] }
    assert_equal [:message_start, :block_open, :text_delta, :block_close, :message_complete], types
    assert_equal :text,               events[1][:block_type]
    assert_includes events[2][:text], "look at the file"
  end

  test "fixture: assistant tool_use record yields tool_args_delta with JSON input" do
    p     = parser
    lines = File.readlines(FIXTURE, chomp: true)
    lines.first(5).each { |l| p.process(l) }
    events = p.process(lines[5])  # tool_use assistant

    types = events.map { |e| e[:type] }
    assert_equal [:message_start, :block_open, :tool_args_delta, :block_close, :message_complete], types

    block_open = events[1]
    assert_equal :tool_use,           block_open[:block_type]
    assert_equal "Read",              block_open[:name]
    assert_equal "toolu_fixture_001", block_open[:tool_use_id]

    delta  = events[2]
    parsed = JSON.parse(delta[:partial_json])
    assert_includes parsed["file_path"], "space_importer.rb"
  end

  test "fixture: user tool_result yields :tool_result event" do
    events      = parse_fixture
    tool_result = events.find { |e| e[:type] == :tool_result }
    refute_nil tool_result
    assert_equal "toolu_fixture_001", tool_result[:tool_use_id]
    assert_equal false,               tool_result[:is_error]
    assert_includes tool_result[:content], "SpaceImporter"
  end

  test "fixture: isSidechain:true record produces no events" do
    p     = parser
    lines = File.readlines(FIXTURE, chomp: true)
    lines.first(7).each { |l| p.process(l) }
    assert_equal [], p.process(lines[7])  # isSidechain: true
  end

  test "fixture: queue-operation produces no events" do
    p     = parser
    lines = File.readlines(FIXTURE, chomp: true)
    lines.first(8).each { |l| p.process(l) }
    assert_equal [], p.process(lines[8])  # queue-operation
  end

  test "fixture: all events are frozen hashes with symbol keys" do
    events = parse_fixture
    refute_empty events
    events.each do |e|
      assert e.frozen?, "event #{e[:type].inspect} is not frozen"
      e.each_key { |k| assert_kind_of Symbol, k, "key #{k.inspect} is not a Symbol" }
    end
  end

  # ── edge cases ────────────────────────────────────────────────────────────────

  test "empty string returns []" do
    assert_equal [], parser.process("")
  end

  test "blank string returns []" do
    assert_equal [], parser.process("   \n")
  end

  test "nil returns []" do
    assert_equal [], parser.process(nil)
  end

  test "unparseable JSON returns []" do
    assert_equal [], parser.process("{not json")
  end

  test "pre-parsed Hash is accepted" do
    record = {
      "type"       => "user",
      "isSidechain" => false,
      "message"    => { "role" => "user", "content" => "hello" },
      "sessionId"  => "sess-xyz",
      "cwd"        => "/tmp"
    }
    events = parser.process(record)
    refute_empty events
    start = events.find { |e| e[:type] == :message_start }
    assert_equal "user", start[:role]
  end

  test "non-message record types return []" do
    assert_equal [], parser.process('{"type":"last-prompt","leafUuid":"u1","sessionId":"s1"}')
    assert_equal [], parser.process('{"type":"permission-mode","mode":"auto","sessionId":"s1"}')
    assert_equal [], parser.process('{"type":"file-history-snapshot","messageId":"m1","snapshot":{}}')
  end

  test "assistant with empty content array returns message lifecycle with no blocks" do
    record = {
      "type"        => "assistant",
      "isSidechain" => false,
      "sessionId"   => "s1",
      "cwd"         => "/tmp",
      "message"     => {
        "id"          => "msg_empty",
        "model"       => "claude-test",
        "role"        => "assistant",
        "content"     => [],
        "stop_reason" => "end_turn",
        "usage"       => {}
      }
    }
    events = parser.process(record)
    types  = events.map { |e| e[:type] }
    assert_equal [:run_init, :message_start, :message_complete], types
  end
end
