# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"

# AC2/AC3: ClaudeCodeHarness#run's transient liveness fiber reads the run log's
# stream-json init event and emits exactly one bounded liveness line to err.
class DispatchLivenessTest < Space::ArchitectTest
  # Emits a stream-json init event naming the pinned --model, then holds long enough
  # for the (short, injected) liveness delay to elapse before exiting.
  FAKE_INIT_MATCH = <<~RUBY
    #!/usr/bin/env ruby
    require "json"
    $stdin.read
    i = ARGV.index("--model")
    model = i ? ARGV[i + 1] : "unknown"
    $stdout.puts JSON.generate("type" => "system", "subtype" => "init", "model" => model)
    $stdout.flush
    sleep 1.0
    exit 0
  RUBY

  # Emits an init event naming a DIFFERENT model than whatever --model pins.
  FAKE_INIT_MISMATCH = <<~RUBY
    #!/usr/bin/env ruby
    require "json"
    $stdin.read
    $stdout.puts JSON.generate("type" => "system", "subtype" => "init", "model" => "actually-a-different-model")
    $stdout.flush
    sleep 1.0
    exit 0
  RUBY

  # Grows the log with non-init, non-JSON output (streamed_init_model finds no model).
  FAKE_GARBAGE = <<~RUBY
    #!/usr/bin/env ruby
    $stdin.read
    $stdout.puts "not json at all"
    $stdout.flush
    sleep 1.0
    exit 0
  RUBY

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

  def with_harness(script, model:)
    root = Dir.mktmpdir("liveness-test")
    bin = File.join(root, "fake")
    File.write(bin, script)
    File.chmod(0o755, bin)
    wt = File.join(root, "wt")
    FileUtils.mkdir_p(wt)
    prompt = File.join(root, "prompt.md")
    File.write(prompt, "go\n")
    run_log = File.join(root, "run.jsonl")
    harness = Space::Architect::Harness::ClaudeCodeHarness.new(model: model, max_turns: 5, bin: bin)
    yield harness, wt, prompt, run_log, StringIO.new
  ensure
    FileUtils.rm_rf(root)
  end

  def liveness_lines(err)
    err.string.lines.grep(/^liveness:/)
  end

  # AC3: matching streamed model → exactly one non-WARN OK line naming the model.
  def test_liveness_ok_line_when_model_matches
    with_harness(FAKE_INIT_MATCH, model: "claude-sonnet-4-6") do |h, wt, prompt, log, err|
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 0.3, err: err)
      lines = liveness_lines(err)

      assert_equal 0, code
      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/\Aliveness: OK streaming model=claude-sonnet-4-6 /, lines.first)
      refute_match(/WARN/, lines.first)
    end
  end

  # AC3: streamed model NOT matching the pinned --model → distinct WARN naming both.
  def test_liveness_warn_line_when_model_mismatches
    with_harness(FAKE_INIT_MISMATCH, model: "claude-sonnet-4-6") do |h, wt, prompt, log, err|
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 0.3, err: err)
      lines = liveness_lines(err)

      assert_equal 0, code
      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/WARN model mismatch/, lines.first)
      assert_match(/pinned=claude-sonnet-4-6/, lines.first)
      assert_match(/streamed=actually-a-different-model/, lines.first)
    end
  end

  # AC3: log still empty after the delay → WARN naming the no-growth condition.
  def test_liveness_warn_line_when_log_empty
    with_harness(FAKE_SILENT, model: "claude-sonnet-4-6") do |h, wt, prompt, log, err|
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 0.3, err: err)
      lines = liveness_lines(err)

      assert_equal 0, code
      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/WARN no growth/, lines.first)
    end
  end

  # AC2: log growing but no parseable init event → best-effort WARN, never raises.
  def test_liveness_warn_line_when_no_init_event
    with_harness(FAKE_GARBAGE, model: "claude-sonnet-4-6") do |h, wt, prompt, log, err|
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 0.3, err: err)
      lines = liveness_lines(err)

      assert_equal 0, code
      assert_equal 1, lines.length, "exactly one liveness line, got: #{err.string.inspect}"
      assert_match(/WARN model unverified/, lines.first)
    end
  end

  # AC2: the transient fiber never keeps the reactor alive — run returns promptly when
  # the child exits even though the liveness delay has not elapsed, and emits no line.
  def test_liveness_fiber_does_not_keep_reactor_alive
    with_harness(FAKE_FAST, model: "claude-sonnet-4-6") do |h, wt, prompt, log, err|
      t0 = Time.now
      code = h.run(prompt_path: prompt, run_log_path: log, chdir: wt, liveness_delay: 5.0, err: err)
      elapsed = Time.now - t0

      assert_equal 0, code
      assert elapsed < 2.0, "run must return promptly on child exit (got #{elapsed.round(2)}s)"
      assert_empty liveness_lines(err), "no liveness line when child exits before the delay"
    end
  end

  # AC2: run_detached gets no liveness fiber (and no err arg) — a plain pid return.
  def test_run_detached_has_no_liveness_fiber
    with_harness(FAKE_FAST, model: "claude-sonnet-4-6") do |h, wt, prompt, log, _err|
      pid = h.run_detached(prompt_path: prompt, run_log_path: log, chdir: wt)
      assert_instance_of Integer, pid
      assert pid > 0
    end
  end
end
