# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "tmpdir"

class DispatcherTest < Space::ArchitectTest
  FAKE_CLAUDE_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    a = ARGV; c = Dir.pwd; s = $stdin.gets
    $stdout.puts "argv=" + a.inspect
    $stdout.puts "cwd=" + c.inspect
    $stdout.puts "stdin=" + (s || "").chomp
    $stdout.flush
    exit((ENV["FAKE_EXIT"] || "0").to_i)
  RUBY

  # Template space + my-repo (identical across every call): build the git fixtures once
  # per test run and cp_r them into each test's tmpdir instead of paying for `git
  # init`/`git commit` subprocess spawns every time.
  def self.template_space_dir
    @template_space_dir ||= begin
      root      = Dir.mktmpdir("dispatcher-template")
      space_dir = File.join(root, "space")
      FileUtils.mkdir_p(space_dir)
      data = {
        "id" => "x", "title" => "T", "status" => "active",
        "repos" => [], "notes" => [], "tickets" => [], "tags" => []
      }
      File.write(File.join(space_dir, "space.yaml"), YAML.dump(data))
      system("git", "-C", space_dir, "init", "-q")
      system("git", "-C", space_dir, "config", "user.email", "t@t")
      system("git", "-C", space_dir, "config", "user.name", "t")
      system("git", "-C", space_dir, "add", "space.yaml")
      system("git", "-C", space_dir, "commit", "-q", "-m", "init")

      repo_dir = File.join(space_dir, "repos", "my-repo")
      FileUtils.mkdir_p(repo_dir)
      system("git", "-C", repo_dir, "init", "-q")
      system("git", "-C", repo_dir, "config", "user.email", "t@t")
      system("git", "-C", repo_dir, "config", "user.name", "t")
      File.write(File.join(repo_dir, "f.txt"), "x")
      system("git", "-C", repo_dir, "add", "f.txt")
      system("git", "-C", repo_dir, "commit", "-q", "-m", "c0")
      space_dir
    end
  end

  def setup_space_with_worktree(root)
    space_dir = File.join(root, "space")
    FileUtils.cp_r(self.class.template_space_dir, space_dir)

    fake = File.join(root, "fake_claude")
    File.write(fake, FAKE_CLAUDE_SCRIPT)
    File.chmod(0o755, fake)

    space   = Space::Core::Space.load(space_dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A")

    build_dir = File.join(space_dir, "build", "I01-demo-A")
    FileUtils.mkdir_p(build_dir)
    File.write(File.join(build_dir, "prompt.md"), "PROMPT-MARKER-42\nrest\n")

    [space_dir, project, fake, build_dir]
  end

  def test_dispatch_writes_run_jsonl_with_policy_flags
    root = Dir.mktmpdir("dispatcher-test")
    _space_dir, project, fake, build_dir = setup_space_with_worktree(root)

    res = project.dispatch("demo", "A", claude_bin: fake)
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert File.exist?(File.join(build_dir, "run.jsonl")), "run.jsonl must exist"
    refute log.strip.empty?, "run.jsonl must be non-empty"
    assert_includes log, "claude-sonnet-4-6"
    assert_includes log, "stream-json"
    assert_includes log, "acceptEdits"
    assert_includes log, "Bash(git commit"
    assert_includes log, "--max-turns"
    assert_includes log, "I01-demo-A/wt"
    assert_includes log, "PROMPT-MARKER-42"
    assert_equal 0, res[:exit_code]
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_reflects_nonzero_exit_code
    root = Dir.mktmpdir("dispatcher-test")
    _space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    with_env("FAKE_EXIT" => "7") do
      res = project.dispatch("demo", "A", claude_bin: fake)
      assert_equal 7, res[:exit_code]
    end
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_raises_error_when_prompt_missing
    root = Dir.mktmpdir("dispatcher-test")
    _space_dir, project, fake, build_dir = setup_space_with_worktree(root)
    File.delete(File.join(build_dir, "prompt.md"))

    assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A", claude_bin: fake)
    end
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_records_dispatched_at_in_space_yaml
    root = Dir.mktmpdir("dispatcher-dispatched-at")
    space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    fixed_now = Time.iso8601("2026-06-15T09:30:00-05:00")
    project.dispatch("demo", "A", claude_bin: fake, now: fixed_now)

    yaml = YAML.load_file(File.join(space_dir, "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes", 0)
    assert_equal fixed_now.iso8601, lane["dispatched_at"]
    assert Time.iso8601(lane["dispatched_at"]), "dispatched_at must parse as ISO8601"
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_detach_records_dispatched_at_in_space_yaml
    root = Dir.mktmpdir("dispatcher-dispatched-at-detach")
    space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    fixed_now = Time.iso8601("2026-06-15T10:00:00-05:00")
    project.dispatch("demo", "A", claude_bin: fake, detach: true, now: fixed_now)

    yaml = YAML.load_file(File.join(space_dir, "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes", 0)
    assert_equal fixed_now.iso8601, lane["dispatched_at"]
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  def test_dispatch_overwrites_dispatched_at_on_redispatch
    root = Dir.mktmpdir("dispatcher-dispatched-at-overwrite")
    space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    first_now = Time.iso8601("2026-06-15T09:00:00-05:00")
    project.dispatch("demo", "A", claude_bin: fake, now: first_now)

    second_now = Time.iso8601("2026-06-15T11:00:00-05:00")
    project.dispatch("demo", "A", claude_bin: fake, now: second_now)

    yaml = YAML.load_file(File.join(space_dir, "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes", 0)
    assert_equal second_now.iso8601, lane["dispatched_at"]
  ensure
    FileUtils.rm_rf(root)
  end

  FAKE_DETACH_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    $stdout.puts "pid=\#{Process.pid}"
    $stdout.flush
    sleep 0.05
    $stdout.puts "done"
    $stdout.flush
    exit 0
  RUBY

  def test_dispatcher_run_detached_returns_integer_pid
    root = Dir.mktmpdir("dispatcher-test")
    fake_bin = File.join(root, "fake_detach")
    File.write(fake_bin, FAKE_DETACH_SCRIPT)
    File.chmod(0o755, fake_bin)

    wt_dir  = File.join(root, "wt")
    FileUtils.mkdir_p(wt_dir)
    prompt  = File.join(root, "prompt.md")
    run_log = File.join(root, "run.jsonl")
    File.write(prompt, "test prompt\n")

    dispatcher = Space::Architect::Dispatcher.new(claude_bin: fake_bin)
    pid = dispatcher.run_detached(prompt_path: prompt, run_log_path: run_log, chdir: wt_dir)

    assert_instance_of Integer, pid
    assert pid > 0
    assert_equal pid, Process.getpgid(pid), "child must be its own pgroup leader"
  ensure
    sleep 0.1
    FileUtils.rm_rf(root)
  end

  # ── I09: pi harness ───────────────────────────────────────────────────────

  FAKE_PI_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    require "json"
    a = ARGV; c = Dir.pwd; s = $stdin.gets
    $stdout.puts JSON.generate({type: "session", version: 3, id: "fake-session", cwd: c})
    $stdout.puts "argv=" + a.inspect
    $stdout.puts "cwd=" + c.inspect
    $stdout.puts "stdin=" + (s || "").chomp
    $stdout.flush
    exit((ENV["FAKE_EXIT"] || "0").to_i)
  RUBY

  def setup_space_with_pi_worktree(root)
    space_dir = File.join(root, "space")
    FileUtils.cp_r(self.class.template_space_dir, space_dir)

    space   = Space::Core::Space.load(space_dir)
    project = Space::Architect::ArchitectProject.new(space: space)
    project.init!
    project.new_iteration!("demo")
    project.worktree_add("my-repo", "demo", "A", harness: "pi", model: "openrouter/test-model")

    build_dir = File.join(space_dir, "build", "I01-demo-A")
    FileUtils.mkdir_p(build_dir)
    File.write(File.join(build_dir, "prompt.md"), "PROMPT-MARKER-42\nrest\n")

    [space_dir, project, build_dir]
  end

  def test_pi_dispatch_writes_run_jsonl_with_session_dir_and_no_no_session
    root = Dir.mktmpdir("dispatcher-pi-test")
    fake_pi = File.join(root, "fake_pi")
    File.write(fake_pi, FAKE_PI_SCRIPT)
    File.chmod(0o755, fake_pi)

    _space_dir, project, build_dir = setup_space_with_pi_worktree(root)

    res = nil
    with_env("ARCHITECT_PI_BIN" => fake_pi) do
      res = project.dispatch("demo", "A")
    end
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert_equal 0, res[:exit_code]
    assert_includes log, "--session-dir"
    assert_includes log, build_dir
    assert_includes log, "\"type\":\"session\""
    assert_includes log, "PROMPT-MARKER-42"
    refute_includes log, "--no-session"
    refute_includes log, ".pi/agent"
  ensure
    FileUtils.rm_rf(root)
  end

  def test_footgun_guard_raises_when_pi_dispatch_uses_default_model
    root = Dir.mktmpdir("dispatcher-pi-guard-test")
    _space_dir, project, _fake, _build_dir = setup_space_with_worktree(root)

    err = assert_raises(Space::Core::Error) do
      project.dispatch("demo", "A", harness: "pi")
    end
    assert_match(/--harness pi/, err.message)
  ensure
    FileUtils.rm_rf(root)
  end

  # I10: pi dispatch + effort no longer raises — it translates to --thinking (full level, unclamped).
  def test_pi_dispatch_combined_with_effort_passes_thinking_flag
    root = Dir.mktmpdir("dispatcher-pi-effort-test")
    fake_pi = File.join(root, "fake_pi")
    File.write(fake_pi, FAKE_PI_SCRIPT)
    File.chmod(0o755, fake_pi)

    _space_dir, project, build_dir = setup_space_with_pi_worktree(root)

    res = nil
    with_env("ARCHITECT_PI_BIN" => fake_pi) do
      res = project.dispatch("demo", "A", effort: "high")
    end
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert_equal 0, res[:exit_code]
    assert_includes log, "--thinking"
    assert_includes log, "\"high\""
  ensure
    FileUtils.rm_rf(root)
  end

  def test_harness_factory_returns_pi_harness_instance
    harness = Space::Architect::Harness.for("pi",
      model: "openrouter/test-model", max_turns: 10, config_dir: Dir.mktmpdir)
    assert_instance_of Space::Architect::Harness::PiHarness, harness
  end

  def test_harness_factory_unknown_harness_message_names_pi
    err = assert_raises(Space::Core::Error) do
      Space::Architect::Harness.for("bogus", model: "x", max_turns: 1, config_dir: Dir.mktmpdir)
    end
    assert_match(/claude-code, opencode, pi/, err.message)
  end

  # ── I10: unified thinking knob — translate, clamp, strip, force, quiet ─────

  def test_thinking_levels_constant_is_pi_fullest_vocabulary
    assert_equal %w[off minimal low medium high xhigh max], Space::Architect::Harness::THINKING_LEVELS
  end

  def test_validate_thinking_level_raises_for_unknown_level
    err = assert_raises(Space::Core::Error) do
      Space::Architect::Harness.validate_thinking_level!("turbo")
    end
    assert_match(/unknown thinking level 'turbo'/, err.message)
    assert_match(/off, minimal, low, medium, high, xhigh, max/, err.message)
  end

  def test_worktree_add_unknown_effort_level_raises
    root = Dir.mktmpdir("dispatcher-unknown-level-test")
    _space_dir, project, _fake, _build_dir = setup_space_with_worktree(root)

    err = assert_raises(Space::Core::Error) do
      project.worktree_add("my-repo", "demo", "B", effort: "turbo")
    end
    assert_match(/unknown thinking level 'turbo'/, err.message)
  ensure
    FileUtils.rm_rf(root)
  end

  def test_opencode_clamps_xhigh_to_high_and_informs
    err_sink = StringIO.new
    harness = Space::Architect::Harness.for("opencode",
      model: "fireworks-ai/accounts/fireworks/models/glm-5p2", max_turns: 10,
      config_dir: Dir.mktmpdir, effort: "xhigh", err: err_sink)

    assert_equal "high",
      harness.builder_config.dig("provider", "fireworks-ai", "models",
        "accounts/fireworks/models/glm-5p2", "options", "reasoningEffort")
    assert_match(/thinking: xhigh .* high/, err_sink.string)
  end

  def test_claude_code_strips_off_and_informs
    err_sink = StringIO.new
    harness = Space::Architect::Harness.for("claude-code",
      model: "claude-sonnet-4-6", max_turns: 10, bin: "/fake", effort: "off", err: err_sink)

    refute_includes harness.send(:argv), "--effort"
    assert_match(/thinking: off/, err_sink.string)
  end

  def test_pi_passes_full_level_unclamped_with_no_inform
    err_sink = StringIO.new
    harness = Space::Architect::Harness.for("pi",
      model: "openrouter/test-model", max_turns: 10, config_dir: Dir.mktmpdir,
      effort: "xhigh", err: err_sink)

    assert_includes harness.send(:argv), "xhigh"
    assert_empty err_sink.string, "pi must not emit a clamp inform — pi's own thinkingLevelMap clamps"
  end

  def test_force_passes_literal_value_unmodified_and_informs
    err_sink = StringIO.new
    harness = Space::Architect::Harness.for("opencode",
      model: "fireworks-ai/accounts/fireworks/models/glm-5p2", max_turns: 10,
      config_dir: Dir.mktmpdir, effort: "xhigh", force: true, err: err_sink)

    assert_equal "xhigh",
      harness.builder_config.dig("provider", "fireworks-ai", "models",
        "accounts/fireworks/models/glm-5p2", "options", "reasoningEffort")
    assert_match(/thinking: force --effort=xhigh \(unmodified, may be rejected\)/, err_sink.string)
  end

  def test_no_level_path_is_byte_for_byte_original_for_all_three_harnesses
    claude = Space::Architect::Harness.for("claude-code", model: "claude-sonnet-4-6", max_turns: 10, bin: "/fake")
    refute_includes claude.send(:argv), "--effort"

    opencode = Space::Architect::Harness.for("opencode",
      model: "fireworks-ai/accounts/fireworks/models/glm-5p2", max_turns: 10, config_dir: Dir.mktmpdir)
    refute opencode.builder_config.key?("provider")

    pi = Space::Architect::Harness.for("pi", model: "openrouter/test-model", max_turns: 10, config_dir: Dir.mktmpdir)
    refute_includes pi.send(:argv), "--thinking"
  end

  def test_dispatch_quiet_suppresses_thinking_inform
    root = Dir.mktmpdir("dispatcher-quiet-test")
    _space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    original_stderr = $stderr
    captured = StringIO.new
    $stderr = captured
    begin
      res = project.dispatch("demo", "A", claude_bin: fake, effort: "off", quiet: true)
      assert_equal 0, res[:exit_code]
    ensure
      $stderr = original_stderr
    end
    assert_empty captured.string, "quiet must suppress the thinking inform line"
  ensure
    FileUtils.rm_rf(root)
  end

  def test_dispatch_without_quiet_emits_thinking_inform_to_stderr
    root = Dir.mktmpdir("dispatcher-noquiet-test")
    _space_dir, project, fake, _build_dir = setup_space_with_worktree(root)

    original_stderr = $stderr
    captured = StringIO.new
    $stderr = captured
    begin
      project.dispatch("demo", "A", claude_bin: fake, effort: "off")
    ensure
      $stderr = original_stderr
    end
    assert_match(/thinking: off/, captured.string)
  ensure
    FileUtils.rm_rf(root)
  end

  def test_model_suffix_parsed_for_opencode_and_stripped
    root = Dir.mktmpdir("dispatcher-suffix-test")
    _space_dir, project, _fake, _build_dir = setup_space_with_worktree(root)

    project.worktree_add("my-repo", "demo", "S", harness: "opencode",
      model: "fireworks-ai/accounts/fireworks/models/glm-5p2:high")

    yaml = YAML.load_file(File.join(root, "space", "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes").find { |l| l["name"] == "S" }
    assert_equal "fireworks-ai/accounts/fireworks/models/glm-5p2", lane["model"]
    assert_equal "high", lane["effort"]
  ensure
    FileUtils.rm_rf(root)
  end

  def test_model_suffix_parsed_for_pi_and_stripped
    root = Dir.mktmpdir("dispatcher-suffix-pi-test")
    _space_dir, project, _fake, _build_dir = setup_space_with_worktree(root)

    project.worktree_add("my-repo", "demo", "S", harness: "pi", model: "openrouter/test-model:high")

    yaml = YAML.load_file(File.join(root, "space", "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes").find { |l| l["name"] == "S" }
    assert_equal "openrouter/test-model", lane["model"]
    assert_equal "high", lane["effort"]
  ensure
    FileUtils.rm_rf(root)
  end

  def test_explicit_effort_flag_overrides_model_suffix
    root = Dir.mktmpdir("dispatcher-suffix-override-test")
    _space_dir, project, _fake, _build_dir = setup_space_with_worktree(root)

    project.worktree_add("my-repo", "demo", "S", harness: "pi",
      model: "openrouter/test-model:high", effort: "low")

    yaml = YAML.load_file(File.join(root, "space", "space.yaml"))
    lane = yaml.dig("project", "iterations", 0, "lanes").find { |l| l["name"] == "S" }
    assert_equal "low", lane["effort"]
  ensure
    FileUtils.rm_rf(root)
  end
end
