# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"
require "json"

# PiHarness#run's transient liveness fiber reads the run log's first pi JSONL
# event whose message.role == "assistant" carries a non-empty model, and emits
# exactly one bounded liveness line to err.
class DispatchLivenessTest < Space::ArchitectTest
  # Never writes to the log; holds past the delay so the fiber sees an empty log.
  FAKE_SILENT = <<~RUBY
    #!/usr/bin/env ruby
    $stdin.read
    sleep 1.0
    exit 0
  RUBY

  # Exits immediately — used to prove the fiber never keeps the reactor alive.
  FAKE_FAST = <<~RUBY
    #!/usr/bin/env ruby
    $stdin.read
    exit 0
  RUBY

  # Writes its assistant-model event after an explicit 0.2s sleep — later than the
  # liveness_delay (0.35s) the late-write test injects, so the log is still empty at
  # the fiber's first check and only grows on a later one. Stays alive a bit longer
  # after writing so the liveness fiber's own poll gets a chance to observe the
  # growth before child.wait returns and stops it.
  FAKE_LATE_WRITER = <<~RUBY
    #!/usr/bin/env ruby
    require "json"
    $stdin.read
    sleep 0.2
    puts JSON.generate("type" => "message_start", "message" => {"role" => "assistant", "model" => "test-model"})
    STDOUT.flush
    sleep 0.3
    exit 0
  RUBY

  # B1: never emits an assistant-model event, but stays alive well past the liveness
  # deadline (0.3s * LIVENESS_BUDGET_FACTOR = 0.9s) so the liveness fiber reaches its
  # own deadline rather than the child exiting first.
  FAKE_NEVER_ASSISTANT = <<~RUBY
    #!/usr/bin/env ruby
    require "json"
    $stdin.read
    sleep 2.0
    puts JSON.generate("type" => "session", "id" => "x")
    STDOUT.flush
    exit 0
  RUBY

  # B1b: writes a non-JSON stderr line immediately (teed into the same run log), then
  # its real assistant-model event 0.2s later — reproducing "one early stderr byte"
  # landing before the parseable event.
  FAKE_STDERR_THEN_ASSISTANT = <<~RUBY
    #!/usr/bin/env ruby
    require "json"
    $stdin.read
    $stderr.puts "noisy stderr line"
    STDERR.flush
    sleep 0.2
    puts JSON.generate("type" => "message_start", "message" => {"role" => "assistant", "model" => "test-model"})
    STDOUT.flush
    sleep 0.3
    exit 0
  RUBY

  def with_harness(script, model:)
    root = Dir.mktmpdir("liveness-test")
    bin = File.join(root, "fake")
    File.write(bin, script)
    File.chmod(0o755, bin)
    wt = File.join(root, "wt")
    FileUtils.mkdir_p(wt)
    config_dir = File.join(root, "config")
    FileUtils.mkdir_p(config_dir)
    prompt = File.join(root, "prompt.md")
    File.write(prompt, "go\n")
    run_log = File.join(root, "run.jsonl")
    harness = Space::Architect::Harness::PiHarness.new(model: model, max_turns: 5, bin: bin, config_dir: config_dir)
    yield harness, wt, prompt, run_log, StringIO.new, bin
  ensure
    FileUtils.rm_rf(root)
  end

  def liveness_lines(err)
    err.string.lines.grep(/^liveness:/)
  end

  # Synthetic pi JSONL assistant event: the message_start frame the real run log
  # carries (verified against a live pi dispatch) — role + model on the message.
  def pi_assistant_event(model)
    JSON.generate("type" => "message_start",
                  "message" => {"role" => "assistant", "provider" => "fireworks", "model" => model})
  end

  # emit_liveness takes a PATH and is a pure function of the run log's contents
  # (see harness.rb) — it never spawns or waits on a child. These three drive it
  # directly against a pre-written log so the OK/WARN message shape is asserted
  # without racing a real child process's VM boot + first write.
  def with_liveness_log(model:)
    root = Dir.mktmpdir("liveness-test")
    log  = Pathname.new(File.join(root, "run.jsonl"))
    harness = Space::Architect::Harness::PiHarness.new(model: model, max_turns: 5, config_dir: root)
    yield harness, log, StringIO.new
  ensure
    FileUtils.rm_rf(root)
  end

  # Matching streamed model → exactly one non-WARN OK line naming the model.
  def test_liveness_ok_line_when_model_matches
    with_liveness_log(model: "test-model") do |h, log, err|
      log.write(pi_assistant_event("test-model") + "\n")
      h.send(:emit_liveness, log, 0.3, err)
      lines = liveness_lines(err)

      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/\Aliveness: OK streaming model=test-model /, lines.first)
      refute_match(/WARN/, lines.first)
    end
  end

  # Streamed model NOT matching the pinned --model → distinct WARN naming both.
  def test_liveness_warn_line_when_model_mismatches
    with_liveness_log(model: "test-model") do |h, log, err|
      log.write(pi_assistant_event("actually-a-different-model") + "\n")
      h.send(:emit_liveness, log, 0.3, err)
      lines = liveness_lines(err)

      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/WARN model mismatch/, lines.first)
      assert_match(/pinned=test-model/, lines.first)
      assert_match(/streamed=actually-a-different-model/, lines.first)
    end
  end

  # Log still empty after the delay → WARN naming the no-growth condition.
  def test_liveness_warn_line_when_log_empty
    with_harness(FAKE_SILENT, model: "test-model") do |h, wt, prompt, log, err|
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 0.3, err: err)
      lines = liveness_lines(err)

      assert_equal 0, code
      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/WARN no growth/, lines.first)
    end
  end

  # The reported duration is the true elapsed wall-clock time, not the raw
  # liveness_delay interpolated verbatim (the fiber's own deadline is 3x the delay).
  def test_liveness_line_reports_true_elapsed_not_raw_delay
    with_harness(FAKE_NEVER_ASSISTANT, model: "test-model") do |h, wt, prompt, log, err|
      liveness_delay = 0.3
      h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: liveness_delay, err: err)
      lines = liveness_lines(err)

      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      reported = lines.first[/empty ([\d.]+)s/, 1].to_f
      true_deadline = liveness_delay * Space::Architect::Harness::PiHarness::LIVENESS_BUDGET_FACTOR

      refute_in_delta liveness_delay, reported, 0.05,
        "reported duration must not be the raw injected liveness_delay: #{lines.first.inspect}"
      assert_in_delta true_deadline, reported, 0.2,
        "reported duration must track the fiber's own true elapsed time (deadline=#{true_deadline}): #{lines.first.inspect}"
    end
  end

  # A single early stderr byte (teed into the run log before the real assistant
  # event) must not satisfy the wait predicate on its own.
  def test_liveness_waits_past_early_stderr_byte_for_assistant_event
    with_harness(FAKE_STDERR_THEN_ASSISTANT, model: "test-model") do |h, wt, prompt, log, err|
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 0.35, err: err)
      lines = liveness_lines(err)

      assert_equal 0, code
      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/\Aliveness: OK streaming model=test-model /, lines.first)
      refute_match(/WARN/, lines.first)
    end
  end

  # A real run() against a child whose first write lands AFTER the injected
  # liveness_delay (0.35s) must still produce the OK line — the fiber's bounded
  # wait, not a single point-sample at the delay instant, is what makes this possible.
  def test_liveness_ok_line_when_child_writes_late
    with_harness(FAKE_LATE_WRITER, model: "test-model") do |h, wt, prompt, log, err|
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 0.35, err: err)
      lines = liveness_lines(err)

      assert_equal 0, code
      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/\Aliveness: OK streaming model=test-model /, lines.first)
      refute_match(/WARN/, lines.first)
    end
  end

  # Log growing but no parseable assistant-model event → best-effort WARN, never raises.
  def test_liveness_warn_line_when_no_assistant_event
    with_liveness_log(model: "test-model") do |h, log, err|
      log.write("not json at all\n")
      h.send(:emit_liveness, log, 0.3, err)
      lines = liveness_lines(err)

      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/WARN model unverified/, lines.first)
    end
  end

  # Non-JSON lines (the stderr tee) are tolerated by the incremental scan — it
  # skips them and keeps reading forward for the next parseable event.
  def test_liveness_scan_tolerates_non_json_lines
    with_liveness_log(model: "test-model") do |h, log, err|
      log.write("noise\n")
      log.write(pi_assistant_event("test-model") + "\n")
      h.send(:emit_liveness, log, 0.3, err)
      lines = liveness_lines(err)

      assert_equal 1, lines.length
      assert_match(/\Aliveness: OK streaming model=test-model /, lines.first)
    end
  end

  # Incremental scan: the predicate runs once against an empty log (memoizing
  # offset 0, finding nothing), the assistant event lands afterward, and
  # emit_liveness must still observe it — a scan forward from the cached offset,
  # never a skipped one.
  def test_emit_liveness_observes_assistant_event_written_after_last_poll
    root = Dir.mktmpdir("harness-liveness-tail-test")
    log = Pathname.new(File.join(root, "run.jsonl"))
    harness = Space::Architect::Harness::PiHarness.new(model: "test-model", max_turns: 5, config_dir: root)

    File.write(log, "")
    refute harness.send(:assistant_model_ready?, log), "empty log must not report an assistant event yet"

    log.open("a") { |f| f.write(pi_assistant_event("test-model") + "\n") }

    err = StringIO.new
    harness.send(:emit_liveness, log, 0.4, err)

    assert_match(/\Aliveness: OK streaming model=test-model /, err.string.lines.first)
  ensure
    FileUtils.rm_rf(root)
  end

  # The transient fiber never keeps the reactor alive — run returns promptly when
  # the child exits even though the liveness delay has not elapsed, and emits no line.
  def test_liveness_fiber_does_not_keep_reactor_alive
    with_harness(FAKE_FAST, model: "test-model") do |h, wt, prompt, log, err|
      t0 = Time.now
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 5.0, err: err)
      elapsed = Time.now - t0

      assert_equal 0, code
      assert elapsed < 2.0, "run must return promptly on child exit (got #{elapsed.round(2)}s)"
      assert_empty liveness_lines(err), "no liveness line when child exits before the delay"
    end
  end

  # run_detached gets no liveness fiber (and no err arg) — a plain pid return.
  def test_run_detached_has_no_liveness_fiber
    with_harness(FAKE_FAST, model: "test-model") do |h, wt, prompt, log, _err|
      pid = h.run_detached(prompt_path: prompt, run_log_path: log, chdir: wt)
      assert_instance_of Integer, pid
      assert pid > 0
    end
  end

  # The liveness line lands on the threaded err writer, so a quiet dispatch (which
  # threads a null writer) suppresses it.
  def test_liveness_line_goes_to_threaded_err_writer
    with_harness(FAKE_LATE_WRITER, model: "test-model") do |h, wt, prompt, log, err, bin|
      h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 0.35, err: err)
      assert_equal 1, liveness_lines(err).length

      nulled = File.open(File::NULL, "w")
      h2 = Space::Architect::Harness::PiHarness.new(model: "test-model", max_turns: 5,
                                                    bin: bin, config_dir: File.dirname(log.to_s))
      log_path = Pathname.new(log.to_s)
      h2.run(prompt_path: Pathname.new(prompt), run_log_path: log_path, chdir: wt,
             liveness_delay: 0.35, err: nulled)
      # the second run added no liveness line — the threaded (null) writer took it
      assert_equal 1, liveness_lines(err).length
    ensure
      nulled.close
    end
  end
end
