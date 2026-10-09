# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class PiEventsTest < Space::ArchitectTest
  EV = Space::Architect::Research::PiEvents

  SESSION = { "type" => "session", "id" => "s1", "timestamp" => "2001-09-09T01:46:40.000Z" }.freeze

  def assistant_message_end(content:, stop_reason:, ts:)
    { "type" => "message_end", "message" => { "role" => "assistant", "content" => content,
                                              "stopReason" => stop_reason, "timestamp" => ts } }
  end

  def events
    [
      SESSION,
      { "type" => "turn_start" },
      assistant_message_end(content: [{ "type" => "text", "text" => "checking " },
                                      { "type" => "toolCall", "id" => "t1", "name" => "read", "arguments" => {} }],
                            stop_reason: "toolUse", ts: 1_000_000_000_500),
      { "type" => "turn_end" },
      { "type" => "turn_start" },
      { "type" => "message_start", "message" => { "role" => "assistant", "content" => [] } },
      assistant_message_end(content: [{ "type" => "thinking", "thinking" => "hmm" },
                                      { "type" => "text", "text" => "done" }],
                            stop_reason: "stop", ts: 1_000_000_001_200),
      { "type" => "turn_end" },
      { "type" => "agent_end" },
      { "type" => "agent_settled", "aborted" => false }
    ]
  end

  def test_last_assistant_message_is_the_stream_final_one
    last = EV.last_assistant_message(events)
    assert_equal "stop", last["stopReason"]
    assert_equal "done", EV.message_text(last)
  end

  def test_message_start_and_replays_are_not_content_sources
    assert_equal "done", EV.message_text(EV.last_assistant_message(events))
  end

  def test_stop_reason_nil_without_assistant_message_end
    assert_nil EV.stop_reason([{ "type" => "session", "timestamp" => "x" }])
  end

  def test_failed_stop_reasons
    assert EV.failed_stop_reason?("error")
    assert EV.failed_stop_reason?("aborted")
    refute EV.failed_stop_reason?("stop")
    refute EV.failed_stop_reason?(nil)
  end

  def test_message_text_joins_all_text_blocks
    message = { "content" => [{ "type" => "text", "text" => "a" },
                              { "type" => "toolCall" },
                              { "type" => "text", "text" => "b" }] }
    assert_equal "ab", EV.message_text(message)
  end

  def test_message_text_empty_for_tool_only_message
    message = { "content" => [{ "type" => "toolCall", "id" => "t1", "name" => "read", "arguments" => {} }] }
    assert_equal "", EV.message_text(message)
  end

  def test_duration_spans_session_to_last_assistant_timestamp
    assert_equal 1.2, EV.duration_seconds(events)
  end

  def test_duration_nil_without_session_or_end
    assert_nil EV.duration_seconds([{ "type" => "turn_end" }])
    assert_nil EV.duration_seconds([SESSION, { "type" => "turn_end" }])
  end

  def test_turn_count_counts_turn_ends
    assert_equal 2, EV.turn_count(events)
  end
end
