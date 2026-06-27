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

  # ── L0 ────────────────────────────────────────────────────────────────────

  def test_l0_quiet_emits_nothing_for_success
    ev = load_events("success")
    out = renderer(level: 0).render(lane: "x", events: ev, alive: false)
    assert out.strip.empty?, "L0 must emit nothing: #{out.inspect}"
  end

  def test_l0_quiet_emits_nothing_for_error
    ev = load_events("error")
    out = renderer(level: 0).render(lane: "x", events: ev, alive: false)
    assert out.strip.empty?, "L0 error must emit nothing: #{out.inspect}"
  end

  # ── L1 ────────────────────────────────────────────────────────────────────

  def test_l1_success_has_complete_mark
    ev = load_events("success")
    out = renderer(level: 1).render(lane: "a", events: ev, alive: false)
    assert_includes out, "✓"
    assert_includes out, "complete"
  end

  def test_l1_success_has_duration_and_turns
    ev = load_events("success")
    out = renderer(level: 1).render(lane: "a", events: ev, alive: false)
    assert_includes out, "1.2s"
    assert_includes out, "3 turns"
  end

  def test_l1_no_assistant_text
    ev = load_events("success")
    out = renderer(level: 1).render(lane: "a", events: ev, alive: false)
    refute_includes out, "RESEARCH_TEXT", "L1 must not leak assistant text"
  end

  def test_l1_error_renders_failed_mark
    ev = load_events("error")
    out = renderer(level: 1).render(lane: "a", events: ev, alive: false)
    assert_includes out, "✗"
    refute_includes out, "✓"
  end

  def test_l1_alive_shows_running
    out = renderer(level: 1).render(lane: "a", events: [], alive: true)
    assert_includes out, "running"
  end

  # ── L2 ────────────────────────────────────────────────────────────────────

  def test_l2_includes_assistant_text
    ev = load_events("success")
    out = renderer(level: 2).render(lane: "a", events: ev, alive: false)
    assert_includes out, "RESEARCH_TEXT"
  end

  def test_l2_no_tool_names
    ev = load_events("success")
    out = renderer(level: 2).render(lane: "a", events: ev, alive: false)
    refute_includes out, "tool: WebFetch"
  end

  # ── L3 ────────────────────────────────────────────────────────────────────

  def test_l3_includes_tool_names
    ev = load_events("success")
    out = renderer(level: 3).render(lane: "a", events: ev, alive: false)
    assert_includes out, "WebFetch"
  end

  def test_l3_no_tool_inputs
    ev = load_events("success")
    out = renderer(level: 3).render(lane: "a", events: ev, alive: false)
    refute_includes out, "example.com"
  end

  # ── L4 ────────────────────────────────────────────────────────────────────

  def test_l4_includes_tool_inputs
    ev = load_events("success")
    out = renderer(level: 4).render(lane: "a", events: ev, alive: false)
    assert_includes out, "example.com"
  end

  def test_l4_includes_tool_results
    ev = load_events("success")
    out = renderer(level: 4).render(lane: "a", events: ev, alive: false)
    assert_includes out, "RESULT_BODY"
  end

  # ── --thinking ─────────────────────────────────────────────────────────────

  def test_thinking_flag_reveals_thinking_block
    ev = load_events("success")
    out = renderer(level: 1, thinking: true).render(lane: "a", events: ev, alive: false)
    assert_includes out, "THINK_TEXT"
  end

  def test_no_thinking_hides_thinking_block
    ev = load_events("success")
    out = renderer(level: 4).render(lane: "a", events: ev, alive: false)
    refute_includes out, "THINK_TEXT"
  end

  # ── --jsonl ─────────────────────────────────────────────────────────────────

  def test_jsonl_emits_lane_tagged_raw_jsonl
    ev = load_events("success")
    out = renderer(level: 1, jsonl: true).render(lane: "lane01", events: ev, alive: false)
    lines = out.strip.split("\n")
    assert lines.all? { |l| l.start_with?("[lane01]") }, "all lines must be lane-tagged: #{lines.inspect}"
    # Each line after the tag must be valid JSON
    lines.each do |l|
      json_part = l.sub(/\A\[lane01\] /, "")
      assert JSON.parse(json_part), "must be valid JSON: #{json_part}"
    end
  end

  def test_jsonl_overrides_level
    ev = load_events("success")
    out_jsonl = renderer(level: 0, jsonl: true).render(lane: "x", events: ev, alive: false)
    refute out_jsonl.strip.empty?, "--jsonl overrides quiet"
  end

  # ── lane prefix ─────────────────────────────────────────────────────────────

  def test_lane_prefix_on_all_lines
    ev = load_events("success")
    out = renderer(level: 4, thinking: true).render(lane: "mylane", events: ev, alive: false)
    out.split("\n").each do |line|
      assert line.start_with?("[mylane]"), "every line must be [lane]-prefixed: #{line.inspect}"
    end
  end

  # ── error surfaces at L1 ─────────────────────────────────────────────────

  def test_error_surfaces_at_l1
    ev = load_events("error")
    out = renderer(level: 1).render(lane: "e", events: ev, alive: false)
    assert_includes out, "✗", "error must surface at L1"
  end
end
