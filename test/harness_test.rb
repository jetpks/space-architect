# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "json"
require "tmpdir"

class HarnessTest < Space::ArchitectTest
  FAKE_PI_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    a = ARGV; c = Dir.pwd; s = $stdin.gets
    $stdout.puts "argv=" + a.inspect
    $stdout.puts "cwd=" + c.inspect
    $stdout.puts "stdin=" + (s || "").chomp
    $stdout.flush
    exit((ENV["FAKE_EXIT"] || "0").to_i)
  RUBY

  # Template space + my-repo (identical across every setup_space call): build the git
  # fixtures once per test run and cp_r them into each test's tmpdir instead of paying
  # for `git init`/`git commit` subprocess spawns every time.
  def self.template_space_dir
    @template_space_dir ||= begin
      root      = Dir.mktmpdir("harness-template")
      space_dir = File.join(root, "space")
      FileUtils.mkdir_p(space_dir)
      data = {
        "id" => "x", "title" => "T", "status" => "active",
        "repos" => [], "notes" => [], "tickets" => [], "tags" => []
      }
      File.write(File.join(space_dir, "space.yaml"), YAML.dump(data))
      Space::GitFixtureTemplate.init_repo(space_dir)
      system("git", "-C", space_dir, "config", "user.email", "t@t")
      system("git", "-C", space_dir, "config", "user.name", "t")
      system("git", "-C", space_dir, "add", "space.yaml")
      system("git", "-C", space_dir, "commit", "-q", "-m", "init")

      repo_dir = File.join(space_dir, "repos", "my-repo")
      FileUtils.mkdir_p(repo_dir)
      Space::GitFixtureTemplate.init_repo(repo_dir)
      system("git", "-C", repo_dir, "config", "user.email", "t@t")
      system("git", "-C", repo_dir, "config", "user.name", "t")
      File.write(File.join(repo_dir, "f.txt"), "x")
      system("git", "-C", repo_dir, "add", "f.txt")
      system("git", "-C", repo_dir, "commit", "-q", "-m", "c0")
      space_dir
    end
  end

  # Shared setup: minimal space + worktree + prompt.md + fake pi binary
  def setup_space(root)
    space_dir = File.join(root, "space")
    FileUtils.cp_r(self.class.template_space_dir, space_dir)

    fake_pi = File.join(root, "fake_pi")
    File.write(fake_pi, FAKE_PI_SCRIPT)
    File.chmod(0o755, fake_pi)

    space   = Space::Core::Space.load(space_dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")

    build_dir = File.join(space_dir, "build", "I01-demo-A")
    FileUtils.mkdir_p(build_dir)
    File.write(File.join(build_dir, "prompt.md"), "PROMPT-MARKER-99\nrest\n")

    [space_dir, project, fake_pi, build_dir]
  end

  # ── PiHarness run through dispatch ───────────────────────────────────────

  def test_pi_harness_run_writes_log_and_exits_zero
    root = Dir.mktmpdir("harness-test")
    _space_dir, project, fake_pi, build_dir = setup_space(root)

    res = project.dispatch("demo", "A", bin: fake_pi)
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert_equal 0, res[:exit_code]
    assert_includes log, "--mode"
    assert_includes log, "json"
    assert_includes log, "PROMPT-MARKER-99"
  ensure
    FileUtils.rm_rf(root)
  end

  # ── factory: pi is the only backend ──────────────────────────────────────

  def test_harness_factory_returns_pi_harness
    harness = Space::Architect::Harness.for("pi",
                                            model: "m", max_turns: 10, bin: "/fake",
                                            config_dir: Dir.mktmpdir)
    assert_instance_of Space::Architect::Harness::PiHarness, harness
  end

  # Any name other than "pi" — including a stored legacy name from an old
  # space.yaml — raises an actionable error naming pi as the only valid harness.
  def test_harness_factory_rejects_everything_but_pi
    %w[legacy-a legacy-b bogus].each do |name|
      err = assert_raises(Space::Core::Error) do
        Space::Architect::Harness.for(name, model: "m", max_turns: 1, config_dir: Dir.mktmpdir)
      end
      assert_match(/'pi' is the only valid harness/, err.message)
      assert_match(/#{name}/, err.message)
    end
  end

  # ── default model ────────────────────────────────────────────────────────

  def test_default_model_constant_value
    assert_equal "accounts/fireworks/models/glm-5p3-flash", Space::Architect::Harness::DEFAULT_MODEL
  end

  def test_dispatch_without_model_resolves_to_pi_default
    root = Dir.mktmpdir("harness-test")
    _space_dir, project, _fake_pi, _build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    ENV["ARGV_RECORD_FILE"] = argv_file

    project.dispatch("demo", "A", bin: recorder)
    recorded = File.read(argv_file).split("\x00")

    idx = recorded.index("--model")
    refute_nil idx, "argv must carry --model: #{recorded.inspect}"
    assert_equal "accounts/fireworks/models/glm-5p3-flash", recorded[idx + 1]
  end

  # ── translate_thinking: unchanged passthrough ────────────────────────────

  def test_translate_thinking_passthrough
    translated, inform = Space::Architect::Harness::PiHarness.translate_thinking("high")
    assert_equal "high", translated
    assert_nil inform
  end

  def test_translate_thinking_nil_level_is_noop
    translated, inform = Space::Architect::Harness::PiHarness.translate_thinking(nil)
    assert_nil translated
    assert_nil inform
  end

  def test_translate_thinking_force_passes_level_with_inform
    translated, inform = Space::Architect::Harness::PiHarness.translate_thinking("bogus", force: true)
    assert_equal "bogus", translated
    assert_match(/force/, inform)
  end

  # ── argv assembly ────────────────────────────────────────────────────────

  # The full builder flag set: -p --mode json --model <m> --session-dir <d>
  # --no-approve -e <guard>, and --thinking only when effort is set.
  def test_dispatch_argv_carries_pi_builder_flag_set
    root = Dir.mktmpdir("harness-test")
    _space_dir, project, _fake_pi, build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    ENV["ARGV_RECORD_FILE"] = argv_file

    project.dispatch("demo", "A", bin: recorder, model: "test-model")
    recorded = File.read(argv_file).split("\x00")

    assert_equal "-p", recorded[0]
    assert_equal "--mode", recorded[1]
    assert_equal "json", recorded[2]
    assert_equal ["--model", "test-model"], recorded[3, 2]
    assert_equal "--session-dir", recorded[5]
    assert_equal build_dir, recorded[6]
    assert_includes recorded, "--no-approve"
    assert_includes recorded, "-e"
    refute_includes recorded, "--thinking", "no --thinking without effort"
    refute_includes recorded, "PROMPT-MARKER-99", "prompt arrives on stdin, not argv"
  ensure
    FileUtils.rm_rf(root)
  end

  # effort set → --thinking <level> in argv.
  def test_dispatch_effort_becomes_thinking_flag
    root = Dir.mktmpdir("harness-test")
    _space_dir, project, _fake_pi, _build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    ENV["ARGV_RECORD_FILE"] = argv_file

    project.dispatch("demo", "A", bin: recorder, effort: "high")
    recorded = File.read(argv_file).split("\x00")

    idx = recorded.index("--thinking")
    refute_nil idx, "argv must carry --thinking with effort set: #{recorded.inspect}"
    assert_equal "high", recorded[idx + 1]
  end

  # The prompt arrives on stdin (never argv).
  def test_dispatch_prompt_arrives_on_stdin
    root = Dir.mktmpdir("harness-test")
    _space_dir, project, fake_pi, build_dir = setup_space(root)

    project.dispatch("demo", "A", bin: fake_pi)
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert_includes log, "stdin=PROMPT-MARKER-99"
    argv_line = log.lines.find { |l| l.start_with?("argv=") }
    refute_includes argv_line, "PROMPT-MARKER-99"
  ensure
    FileUtils.rm_rf(root)
  end

  # ── guard wiring at the dispatch level ───────────────────────────────────

  # Dispatch vendors the builder guard into the lane's build dir (byte-for-byte
  # with the shipped extension) and injects it via -e <absolute path>.
  def test_dispatch_copies_guard_and_injects_via_e
    root = Dir.mktmpdir("harness-test")
    _space_dir, project, _fake_pi, build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    ENV["ARGV_RECORD_FILE"] = argv_file

    project.dispatch("demo", "A", bin: recorder)
    recorded = File.read(argv_file).split("\x00")

    vendored = File.expand_path("../lib/space_architect/pi/builder-guard.ts", __dir__)
    copied = File.join(build_dir, "builder-guard.ts")
    assert File.exist?(copied), "guard must be copied to the build dir"
    assert_equal File.binread(vendored), File.binread(copied), "copy must be byte-for-byte"

    idx = recorded.index("-e")
    refute_nil idx, "argv must carry -e: #{recorded.inspect}"
    assert_equal copied, recorded[idx + 1]
    assert_path_exists recorded[idx + 1]
  ensure
    FileUtils.rm_rf(root)
  end

  # The guard copy is idempotent: a stale file in the build dir is overwritten.
  def test_dispatch_guard_copy_overwrites_stale_file
    root = Dir.mktmpdir("harness-test")
    _space_dir, project, _fake_pi, build_dir = setup_space(root)

    guard_path = File.join(build_dir, "builder-guard.ts")
    FileUtils.mkdir_p(build_dir)
    File.write(guard_path, "stale junk")

    project.dispatch("demo", "A", bin: fake_pi_bin(root))

    vendored = File.expand_path("../lib/space_architect/pi/builder-guard.ts", __dir__)
    assert_equal File.binread(vendored), File.binread(guard_path)
  ensure
    FileUtils.rm_rf(root)
  end

  # Detached dispatch injects the guard too.
  def test_dispatch_detached_copies_guard
    root = Dir.mktmpdir("harness-detach-guard")
    _space_dir, project, _fake_pi, build_dir = setup_space(root)

    project.dispatch("demo", "A", bin: fake_pi_bin(root), detach: true)

    vendored = File.expand_path("../lib/space_architect/pi/builder-guard.ts", __dir__)
    copied = File.join(build_dir, "builder-guard.ts")
    assert File.exist?(copied), "detached dispatch must still vendor the guard"
    assert_equal File.binread(vendored), File.binread(copied)
  ensure
    FileUtils.rm_rf(root)
  end

  # ── dispatch resolution from lane entry ──────────────────────────────────

  # dispatch with no harness/model kwargs reads both from the persisted lane entry.
  def test_dispatch_reads_harness_and_model_from_lane
    root = Dir.mktmpdir("harness-test")
    space_dir, project, _fake_pi, _build_dir = setup_space(root)

    project.worktree_add("my-repo", "demo", "B",
                         harness: "pi",
                         model: "lane-stored-model")
    b_build_dir = File.join(space_dir, "build", "I01-demo-B")
    FileUtils.mkdir_p(b_build_dir)
    File.write(File.join(b_build_dir, "prompt.md"), "PROMPT-B\n")

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    ENV["ARGV_RECORD_FILE"] = argv_file

    project.dispatch("demo", "B", bin: recorder)
    recorded = File.read(argv_file).split("\x00")

    idx = recorded.index("--model")
    assert_equal "lane-stored-model", recorded[idx + 1]

    yml = YAML.safe_load(File.read(File.join(space_dir, "space.yaml")), aliases: false)
    demo = yml.dig("project", "iterations").find { |i| i["name"] == "demo" }
    lane_b = (demo["lanes"] || []).find { |l| l["name"] == "B" }
    assert_equal "pi", lane_b["harness"]
  ensure
    FileUtils.rm_rf(root)
  end

  # Explicit dispatch-time model overrides are stamped onto the persisted lane
  # entry, so `architect status` reflects what actually ran on the last dispatch.
  def test_dispatch_override_stamps_lane_entry
    root = Dir.mktmpdir("harness-test")
    space_dir, project, _fake_pi, _build_dir = setup_space(root)

    project.worktree_add("my-repo", "demo", "C",
                         harness: "pi",
                         model: "original-model")
    c_build_dir = File.join(space_dir, "build", "I01-demo-C")
    FileUtils.mkdir_p(c_build_dir)
    File.write(File.join(c_build_dir, "prompt.md"), "PROMPT-C\n")

    project.dispatch("demo", "C", model: "override-model", bin: fake_pi_bin(root))

    yml = YAML.safe_load(File.read(File.join(space_dir, "space.yaml")), aliases: false)
    iterations = yml.dig("project", "iterations") || []
    demo = iterations.find { |i| i["name"] == "demo" }
    lane_c = (demo["lanes"] || []).find { |l| l["name"] == "C" }
    assert_equal "override-model", lane_c["model"]
    assert_equal "pi", lane_c["harness"]
  ensure
    FileUtils.rm_rf(root)
  end

  # A stored legacy harness name from an old space.yaml raises an actionable
  # error naming pi — it never silently dispatches or defaults.
  def test_dispatch_with_stored_legacy_harness_raises_actionable_error
    root = Dir.mktmpdir("harness-test")
    space_dir, project, _fake_pi, _build_dir = setup_space(root)

    project.worktree_add("my-repo", "demo", "D")
    d_build_dir = File.join(space_dir, "build", "I01-demo-D")
    FileUtils.mkdir_p(d_build_dir)
    File.write(File.join(d_build_dir, "prompt.md"), "PROMPT-D\n")

    space = Space::Core::Space.load(space_dir)
    space.data["project"]["iterations"].find { |i| i["name"] == "demo" }
      .dig("lanes").find { |l| l["name"] == "D" }["harness"] = "legacy-stored"
    space.save

    # dispatch through a fresh load so the stored (mutated) entry is what resolves
    reloaded = Space::Architect::ArchitectProject.new(space: Space::Core::Space.load(space_dir))
    err = assert_raises(Space::Core::Error) { reloaded.dispatch("demo", "D") }
    assert_match(/'pi' is the only valid harness/, err.message)
    assert_match(/legacy-stored/, err.message)
  ensure
    FileUtils.rm_rf(root)
  end

  # ── run_detached ─────────────────────────────────────────────────────────

  FAKE_DETACH_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    $stdout.puts "detach_pid=\#{Process.pid}"
    $stdout.flush
    sleep 0.05
    $stdout.puts "detach_done"
    $stdout.flush
    exit 0
  RUBY

  def test_pi_harness_run_detached_returns_integer_pid
    root = Dir.mktmpdir("harness-detach-test")
    fake_bin = File.join(root, "fake_detach")
    File.write(fake_bin, FAKE_DETACH_SCRIPT)
    File.chmod(0o755, fake_bin)

    config_dir = File.join(root, "config")
    wt_dir     = File.join(root, "wt")
    FileUtils.mkdir_p(config_dir)
    FileUtils.mkdir_p(wt_dir)
    prompt  = File.join(root, "prompt.md")
    run_log = File.join(root, "run.jsonl")
    File.write(prompt, "hello\n")

    harness = Space::Architect::Harness::PiHarness.new(
      model: "test-model", max_turns: 5, bin: fake_bin, config_dir: config_dir
    )
    pid = harness.run_detached(prompt_path: prompt, run_log_path: run_log, chdir: wt_dir)

    assert_instance_of Integer, pid
    assert pid > 0
    assert_equal pid, Process.getpgid(pid), "child must be its own pgroup leader"
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  # ── wall-clock timeout group-kill ────────────────────────────────────────

  FAKE_SLEEP_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    trap("TERM") { exit 143 }
    sleep 300
  RUBY

  # Timeout fires fast (1s), kills the process GROUP, returns 124, leaves no orphan.
  def test_pi_harness_run_timeout_kills_process_group
    root = Dir.mktmpdir("harness-timeout-test")
    fake_bin = File.join(root, "fake_sleep_builder")
    File.write(fake_bin, FAKE_SLEEP_SCRIPT)
    File.chmod(0o755, fake_bin)

    config_dir   = File.join(root, "config")
    wt_dir       = File.join(root, "wt")
    prompt_path  = File.join(root, "prompt.md")
    run_log_path = File.join(root, "run.jsonl")
    FileUtils.mkdir_p(config_dir)
    FileUtils.mkdir_p(wt_dir)
    File.write(prompt_path, "go\n")

    harness = Space::Architect::Harness::PiHarness.new(
      model: "test-model", max_turns: 10, bin: fake_bin, config_dir: config_dir
    )

    t0 = Time.now

    exit_code = harness.run(
      prompt_path:  prompt_path,
      run_log_path: run_log_path,
      chdir:        wt_dir,
      timeout:      0.2
    )

    elapsed = Time.now - t0

    assert_equal Space::Architect::Harness::PiHarness::TIMEOUT_EXIT_CODE, exit_code,
      "timeout must return #{Space::Architect::Harness::PiHarness::TIMEOUT_EXIT_CODE}, got #{exit_code}"
    assert elapsed < 5, "timeout-kill must fire fast (got #{elapsed.round(2)}s, expected < 5s)"

    # No orphaned builder process: pgrep for our fake binary returns nothing.
    orphan_check = system("pgrep", "-f", "fake_sleep_builder", out: File::NULL, err: File::NULL)
    refute orphan_check, "fake_sleep_builder process must not survive after timeout kill"
  ensure
    # Belt-and-suspenders: kill any stray process just in case the test failed mid-run
    system("pkill", "-KILL", "-f", "fake_sleep_builder", out: File::NULL, err: File::NULL)
    FileUtils.rm_rf(root)
  end

  # nil timeout preserves the no-timeout behavior (returns child exit status).
  def test_pi_harness_run_nil_timeout_no_regression
    root = Dir.mktmpdir("harness-nil-timeout")
    _space_dir, project, fake_pi, _build_dir = setup_space(root)

    res = project.dispatch("demo", "A", bin: fake_pi, timeout: nil)
    assert_equal 0, res[:exit_code]
    refute res[:timed_out], "nil timeout must not set timed_out"
  ensure
    FileUtils.rm_rf(root)
  end

  # zero timeout preserves the disabled behavior.
  def test_pi_harness_run_zero_timeout_no_regression
    root = Dir.mktmpdir("harness-zero-timeout")
    _space_dir, project, fake_pi, _build_dir = setup_space(root)

    res = project.dispatch("demo", "A", bin: fake_pi, timeout: 0)
    assert_equal 0, res[:exit_code]
    refute res[:timed_out], "zero timeout must not set timed_out"
  ensure
    FileUtils.rm_rf(root)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Fake binary that records argv to ARGV_RECORD_FILE (null-delimited).
  FAKE_ARGV_RECORDER = <<~RUBY
    #!/usr/bin/env ruby
    File.write(ENV.fetch("ARGV_RECORD_FILE"), ARGV.join("\x00"))
    exit 0
  RUBY

  def fake_pi_bin(root)
    bin = File.join(root, "fake_pi_dispatch")
    File.write(bin, <<~RUBY)
      #!/usr/bin/env ruby
      $stdin.read
      $stdout.puts "ok"
      $stdout.flush
      exit 0
    RUBY
    File.chmod(0o755, bin)
    bin
  end
end
