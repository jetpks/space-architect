# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "tmpdir"

class MuxTest < Space::ArchitectTest
  def make_run(dir, pid: Process.pid)
    Space::Architect::Research::Run.new(
      id: "probe", topic: "probe", pid: pid, dir: Pathname.new(dir),
      prompt_path: Pathname.new(dir).join("prompt.md"),
      run_log_path: Pathname.new(dir).join("run.jsonl"),
      report_path: Pathname.new(dir).join("report.md"),
      model: "m", dispatched_at: Time.now
    )
  end

  def write_stream(dir, events)
    File.write(File.join(dir, "run.jsonl"),
               events.map { |e| JSON.generate(e) }.join("\n") + "\n")
  end

  def session(ts: "2001-09-09T01:46:40.000Z")
    { "type" => "session", "id" => "s1", "timestamp" => ts }
  end

  def assistant_end(text: nil, stop_reason: "stop", ts: 1_000_000_001_200)
    blocks = text ? [{ "type" => "text", "text" => text }] : []
    { "type" => "message_end",
      "message" => { "role" => "assistant", "content" => blocks, "stopReason" => stop_reason, "timestamp" => ts } }
  end

  def mux(run, level: 1, out:, **kwargs)
    renderer = Space::Architect::Research::Renderer.new(level: level)
    Space::Architect::Research::Mux.new([run], renderer: renderer, out: out, **kwargs)
  end

  def dead_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end

  # Spawns a real child and reaps it from a background thread — once it exits
  # the pid is gone (kill(0) → ESRCH), like a detached run.
  def spawn_and_reap(*cmd)
    pid = Process.spawn(*cmd)
    Thread.new { Process.wait(pid) rescue nil }
    pid
  end

  # ── happy path ────────────────────────────────────────────────────────────

  def test_success_extracts_report_and_returns_ok
    Dir.mktmpdir do |dir|
      write_stream(dir, [session, assistant_end(text: "Final research summary here."),
                         { "type" => "turn_end" }, { "type" => "agent_settled", "aborted" => false }])
      out = StringIO.new
      result = mux(make_run(dir), out: out).run

      assert_equal :ok, result
      assert_equal "Final research summary here.", File.read(File.join(dir, "report.md"))
      assert_includes out.string, "✓ complete"
      assert_includes out.string, "STATUS: Final research summary here."
    end
  end

  def test_success_terminal_line_carries_span_and_turns
    Dir.mktmpdir do |dir|
      write_stream(dir, [session, { "type" => "turn_start" },
                         assistant_end(text: "S", ts: 1_000_000_001_200),
                         { "type" => "turn_end" },
                         { "type" => "agent_settled", "aborted" => false }])
      out = StringIO.new
      mux(make_run(dir), out: out).run

      assert_includes out.string, "1.2s"
      assert_includes out.string, "1 turns"
    end
  end

  def test_report_not_written_when_final_text_empty
    Dir.mktmpdir do |dir|
      write_stream(dir, [session, assistant_end(text: nil, stop_reason: "toolUse"),
                         { "type" => "turn_end" }, { "type" => "agent_settled", "aborted" => false }])
      out = StringIO.new
      result = mux(make_run(dir), out: out).run

      assert_equal :failed, result
      refute File.exist?(File.join(dir, "report.md"))
      assert_includes out.string, "✗ failed no final assistant text"
    end
  end

  # ── stopReason classification ─────────────────────────────────────────────

  def test_error_stop_reason_fails_with_reason_from_content
    Dir.mktmpdir do |dir|
      write_stream(dir, [session, assistant_end(text: "exploded midway", stop_reason: "error"),
                         { "type" => "turn_end" }, { "type" => "agent_settled", "aborted" => false }])
      out = StringIO.new
      result = mux(make_run(dir), out: out).run

      assert_equal :failed, result
      assert_includes out.string, "✗ failed exploded midway"
      # Partial output is preserved: the report is the final text, non-empty or
      # not written at all.
      assert_equal "exploded midway", File.read(File.join(dir, "report.md"))
    end
  end

  def test_aborted_stop_reason_without_text_fails_with_stop_reason
    Dir.mktmpdir do |dir|
      write_stream(dir, [session, assistant_end(text: nil, stop_reason: "aborted"),
                         { "type" => "turn_end" }, { "type" => "agent_settled", "aborted" => false }])
      out = StringIO.new
      result = mux(make_run(dir), out: out).run

      assert_equal :failed, result
      assert_includes out.string, "✗ failed aborted"
    end
  end

  def test_agent_settled_aborted_fails
    Dir.mktmpdir do |dir|
      write_stream(dir, [session, assistant_end(text: "partial work"),
                         { "type" => "turn_end" }, { "type" => "agent_settled", "aborted" => true }])
      out = StringIO.new
      result = mux(make_run(dir), out: out).run

      assert_equal :failed, result
      assert_includes out.string, "✗ failed partial work"
    end
  end

  def test_stop_message_without_agent_settled_does_not_break_the_tail
    # A stopReason "stop" assistant message is not run-final: tools may follow.
    # The tail must keep polling (live pid) and only settle on agent_settled.
    Dir.mktmpdir do |dir|
      pid = Process.spawn("sleep", "1")
      write_stream(dir, [session, assistant_end(text: "not final yet"), { "type" => "turn_end" }])

      th = Thread.new do
        sleep 0.3
        File.open(File.join(dir, "run.jsonl"), "a") do |f|
          f.puts(JSON.generate({ "type" => "tool_execution_start", "toolCallId" => "t1",
                                 "toolName" => "read", "args" => {} }))
          f.puts(JSON.generate(assistant_end(text: "now final")))
          f.puts(JSON.generate({ "type" => "turn_end" }))
          f.puts(JSON.generate({ "type" => "agent_settled", "aborted" => false }))
        end
      end

      out = StringIO.new
      result = mux(make_run(dir, pid: pid), out: out).run
      th.join

      assert_equal :ok, result
      assert_equal "now final", File.read(File.join(dir, "report.md"))
    end
  end

  # ── pid death / missing file ──────────────────────────────────────────────

  def test_pid_death_without_agent_settled_fails
    Dir.mktmpdir do |dir|
      pid = spawn_and_reap("sleep", "0.2")
      write_stream(dir, [session, assistant_end(text: "mid-run output"), { "type" => "turn_end" }])

      out = StringIO.new
      result = mux(make_run(dir, pid: pid), out: out).run

      assert_equal :failed, result
      assert_includes out.string, "✗ failed process died without a terminal event"
    end
  end

  def test_missing_run_jsonl_fails
    Dir.mktmpdir do |dir|
      out = StringIO.new
      result = mux(make_run(dir, pid: dead_pid), out: out).run

      assert_equal :failed, result
      assert_includes out.string, "✗ failed run.jsonl never appeared"
    end
  end

  # ── quiet / heartbeat ─────────────────────────────────────────────────────

  def test_quiet_suppresses_all_output
    Dir.mktmpdir do |dir|
      write_stream(dir, [session, assistant_end(text: "Final research summary here."),
                         { "type" => "turn_end" }, { "type" => "agent_settled", "aborted" => false }])
      out = StringIO.new
      result = mux(make_run(dir), level: 0, out: out).run

      assert_equal :ok, result
      assert out.string.empty?, "quiet must suppress all output: #{out.string.inspect}"
    end
  end

  def test_heartbeat_emitted_while_alive
    Dir.mktmpdir do |dir|
      pid = spawn_and_reap("sleep", "1")
      write_stream(dir, [session, { "type" => "turn_end" }]) # no agent_settled

      out = StringIO.new
      result = mux(make_run(dir, pid: pid), out: out, heartbeat_every: 0.1).run

      assert_equal :failed, result
      assert_includes out.string, "⏳ still running…"
    end
  ensure
    Process.kill("KILL", pid) rescue nil
  end
end
