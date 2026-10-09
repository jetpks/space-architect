# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class RendererTest < Space::ArchitectTest
  FIXTURE_ROOT = File.join(__dir__, "../fixtures/research")

  def load_events(name)
    File.readlines(File.join(FIXTURE_ROOT, "#{name}.jsonl")).map { |l| JSON.parse(l.chomp) }
  end

  def renderer(level:, thinking: false, jsonl: false)
    Space::Architect::Research::Renderer.new(level: level, thinking: thinking, jsonl: jsonl)
  end

  # Mirrors the mux: terminal facts derived from the settled stream via PiEvents.
  def render_with_terminal(level:, events:, lane: "a", alive: false, thinking: false, jsonl: false)
    r = renderer(level: level, thinking: thinking, jsonl: jsonl)
    out = r.render(lane: lane, events: events, alive: alive)
    return out unless events.any? { |e| e["type"] == "agent_settled" }

    pi = Space::Architect::Research::PiEvents
    text = pi.message_text(pi.last_assistant_message(events))
    ok = events.none? { |e| e["type"] == "agent_settled" && e["aborted"] == true } &&
         pi.stop_reason(events) == "stop" && !text.empty?
    out + r.terminal(lane: lane, ok: ok,
                     reason:  ok ? nil : pi.stop_reason(events),
                     snippet: ok ? text : nil,
                     duration: pi.duration_seconds(events),
                     turns:    pi.turn_count(events))
  end

  # ── L0 ────────────────────────────────────────────────────────────────────

  def test_l0_quiet_emits_nothing_for_success
    ev = load_events("success")
    out = render_with_terminal(level: 0, events: ev)
    assert out.strip.empty?, "L0 must emit nothing: #{out.inspect}"
  end

  def test_l0_quiet_emits_nothing_for_error
    ev = load_events("error")
    out = render_with_terminal(level: 0, events: ev)
    assert out.strip.empty?, "L0 error must emit nothing: #{out.inspect}"
  end

  # ── L1 ────────────────────────────────────────────────────────────────────

  def test_l1_success_has_complete_mark
    out = render_with_terminal(level: 1, events: load_events("success"))
    assert_includes out, "✓"
    assert_includes out, "complete"
  end

  def test_l1_success_has_span_and_turns
    out = render_with_terminal(level: 1, events: load_events("success"))
    assert_includes out, "1.2s"
    assert_includes out, "2 turns"
  end

  def test_l1_success_is_lifecycle_plus_terminal_only
    out = render_with_terminal(level: 1, events: load_events("success"))
    assert_equal 1, out.lines.size, "L1 must not render event bodies: #{out.inspect}"
    assert_match(/\[a\] ✓ complete/, out)
    refute_includes out, "THINK_TEXT"
  end

  def test_l1_error_renders_failed_mark_with_stop_reason
    out = render_with_terminal(level: 1, events: load_events("error"))
    assert_includes out, "✗"
    assert_includes out, "failed error"
    refute_includes out, "✓"
  end

  def test_l1_alive_shows_running
    out = renderer(level: 1).render(lane: "a", events: [], alive: true)
    assert_includes out, "running"
  end

  # ── L2 ────────────────────────────────────────────────────────────────────

  def test_l2_includes_assistant_text
    out = render_with_terminal(level: 2, events: load_events("success"))
    assert_includes out, "RESEARCH_TEXT"
  end

  def test_l2_no_tool_names
    out = render_with_terminal(level: 2, events: load_events("success"))
    refute_includes out, "tool: WebFetch"
  end

  # ── L3 ────────────────────────────────────────────────────────────────────

  def test_l3_includes_tool_names
    out = render_with_terminal(level: 3, events: load_events("success"))
    assert_includes out, "WebFetch"
  end

  def test_l3_no_tool_inputs
    out = render_with_terminal(level: 3, events: load_events("success"))
    refute_includes out, "example.com"
  end

  # ── L4 ────────────────────────────────────────────────────────────────────

  def test_l4_includes_tool_inputs
    out = render_with_terminal(level: 4, events: load_events("success"))
    assert_includes out, "example.com"
  end

  def test_l4_includes_tool_results
    out = render_with_terminal(level: 4, events: load_events("success"))
    assert_includes out, "RESULT_BODY"
  end

  # ── --thinking ─────────────────────────────────────────────────────────────

  def test_thinking_flag_reveals_thinking_block
    out = render_with_terminal(level: 1, events: load_events("success"), thinking: true)
    assert_includes out, "THINK_TEXT"
  end

  def test_no_thinking_hides_thinking_block
    out = render_with_terminal(level: 4, events: load_events("success"))
    refute_includes out, "THINK_TEXT"
  end

  # ── --jsonl ─────────────────────────────────────────────────────────────────

  def test_jsonl_emits_lane_tagged_raw_jsonl
    out = renderer(level: 1, jsonl: true).render(lane: "lane01", events: load_events("success"), alive: false)
    lines = out.strip.split("\n")
    assert lines.all? { |l| l.start_with?("[lane01]") }, "all lines must be lane-tagged: #{lines.inspect}"
    # Each line after the tag must be valid JSON
    lines.each do |l|
      json_part = l.sub(/\A\[lane01\] /, "")
      assert JSON.parse(json_part), "must be valid JSON: #{json_part}"
    end
  end

  def test_jsonl_overrides_level
    out_jsonl = renderer(level: 0, jsonl: true).render(lane: "x", events: load_events("success"), alive: false)
    refute out_jsonl.strip.empty?, "--jsonl overrides quiet"
  end

  # ── lane prefix ─────────────────────────────────────────────────────────────

  def test_lane_prefix_on_all_lines
    out = render_with_terminal(level: 4, events: load_events("success"), lane: "mylane", thinking: true)
    out.split("\n").each do |line|
      assert line.start_with?("[mylane]"), "every line must be [lane]-prefixed: #{line.inspect}"
    end
  end

  # ── unsettled stream renders no terminal line ──────────────────────────────

  def test_inflight_stream_has_no_terminal_mark
    out = render_with_terminal(level: 1, events: load_events("inflight"), alive: true)
    refute_includes out, "✓"
    refute_includes out, "✗"
  end

  # ── D1: mux-style incremental drive at L1 prints `running` exactly once ───

  def test_l1_incremental_drive_running_once
    ev = load_events("success")
    r = renderer(level: 1)
    out = +""
    out << r.render(lane: "a", events: [], alive: true)
    settled = false
    ev.each do |e|
      settled = true if e["type"] == "agent_settled"
      out << r.render(lane: "a", events: [e], alive: !settled)
    end
    count = out.lines.count { |l| l.include?("running") }
    assert_equal 1, count, "running must appear exactly once in incremental drive, got #{count}"
  end

  # ── terminal line truncates the status snippet at 80 chars ────────────────

  def test_terminal_snippet_truncated_at_80_chars
    long = "A" * 200
    out = renderer(level: 1).terminal(lane: "a", ok: true, snippet: long, duration: 1.2, turns: 2)
    assert_includes out, "A" * 80
    refute_includes out, "A" * 81
  end

  # ── D3: #lifecycle? predicate ─────────────────────────────────────────────

  def test_lifecycle_predicate_true_at_l1
    assert renderer(level: 1).lifecycle?
  end

  def test_lifecycle_predicate_false_at_l0
    refute renderer(level: 0).lifecycle?
  end

  def test_lifecycle_predicate_false_when_jsonl
    refute renderer(level: 1, jsonl: true).lifecycle?
  end
end
