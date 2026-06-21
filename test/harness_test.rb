# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "json"
require "tmpdir"

class HarnessTest < SpaceArchitectTest
  FAKE_CLAUDE_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    a = ARGV; c = Dir.pwd; s = $stdin.gets
    $stdout.puts "argv=" + a.inspect
    $stdout.puts "cwd=" + c.inspect
    $stdout.puts "stdin=" + (s || "").chomp
    $stdout.flush
    exit((ENV["FAKE_EXIT"] || "0").to_i)
  RUBY

  FAKE_OPENCODE_SCRIPT = <<~RUBY
    #!/usr/bin/env ruby
    a = ARGV; c = Dir.pwd
    $stdout.puts "argv=" + a.inspect
    $stdout.puts "cwd=" + c.inspect
    $stdout.puts "OPENCODE_CONFIG=" + (ENV["OPENCODE_CONFIG"] || "").inspect
    $stdout.puts "OPENCODE_DISABLE_PROJECT_CONFIG=" + (ENV["OPENCODE_DISABLE_PROJECT_CONFIG"] || "").inspect
    $stdout.flush
    exit((ENV["FAKE_EXIT"] || "0").to_i)
  RUBY

  # Shared setup: minimal space + worktree + prompt.md + both fake binaries
  def setup_space(root)
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

    fake_claude   = File.join(root, "fake_claude")
    fake_opencode = File.join(root, "fake_opencode")
    File.write(fake_claude,   FAKE_CLAUDE_SCRIPT)
    File.write(fake_opencode, FAKE_OPENCODE_SCRIPT)
    File.chmod(0o755, fake_claude)
    File.chmod(0o755, fake_opencode)

    space   = SpaceArchitect::Space.load(space_dir)
    mission = SpaceArchitect::ArchitectMission.new(space: space)
    mission.init!
    mission.new_iteration!("demo")
    mission.worktree_add("my-repo", "demo", "A")

    build_dir = File.join(space_dir, "build", "I01-demo-A")
    FileUtils.mkdir_p(build_dir)
    File.write(File.join(build_dir, "prompt.md"), "PROMPT-MARKER-99\nrest\n")

    [space_dir, mission, fake_claude, fake_opencode, build_dir]
  end

  # ── ClaudeCodeHarness unit tests ─────────────────────────────────────────

  def test_claude_code_harness_run_writes_log_and_exits_zero
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, fake_claude, _fake_oc, build_dir = setup_space(root)

    res = mission.dispatch("demo", "A", claude_bin: fake_claude)
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert_equal 0, res[:exit_code]
    assert_includes log, "claude-sonnet-4-6"
    assert_includes log, "stream-json"
    assert_includes log, "acceptEdits"
    assert_includes log, "Bash(git commit"
    assert_includes log, "--max-turns"
    assert_includes log, "I01-demo-A/wt"
    assert_includes log, "PROMPT-MARKER-99"
  ensure
    FileUtils.rm_rf(root)
  end

  def test_harness_factory_default_is_claude_code
    harness = SpaceArchitect::Harness.for("claude-code",
                                          model: "claude-sonnet-4-6", max_turns: 10, bin: "/fake")
    assert_instance_of SpaceArchitect::Harness::ClaudeCodeHarness, harness
  end

  # ── OpenCodeHarness unit tests ────────────────────────────────────────────

  def test_builder_config_steps_equals_max_turns
    harness = SpaceArchitect::Harness::OpenCodeHarness.new(
      model: "fireworks-ai/test", max_turns: 42, bin: "opencode",
      config_dir: Dir.mktmpdir
    )
    cfg = harness.builder_config
    assert_equal 42, cfg.dig("agent", "builder", "steps")
  end

  def test_builder_config_denies_git_commit_and_push
    harness = SpaceArchitect::Harness::OpenCodeHarness.new(
      model: "fireworks-ai/test", max_turns: 10, bin: "opencode",
      config_dir: Dir.mktmpdir
    )
    bash = harness.builder_config.dig("agent", "builder", "permission", "bash")
    assert_equal "deny", bash["git commit *"]
    assert_equal "deny", bash["git push *"]
    assert_equal "allow", bash["*"]
  end

  def test_opencode_dispatch_argv_and_env
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, _fake_claude, fake_oc, build_dir = setup_space(root)

    res = mission.dispatch("demo", "A",
                           harness: "opencode",
                           model: "fireworks-ai/accounts/fireworks/models/glm-5p2",
                           opencode_bin: fake_oc)
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert_equal 0, res[:exit_code]
    # AC3: required strings in captured log
    assert_includes log, '"run"'
    assert_includes log, '"--format"'
    assert_includes log, '"json"'
    assert_includes log, "fireworks-ai/accounts/fireworks/models/glm-5p2"
    assert_includes log, '"--dangerously-skip-permissions"'
    assert_includes log, '"--agent"'
    assert_includes log, '"builder"'
    assert_includes log, "I01-demo-A/wt"   # worktree dir via --dir
    # AC4: OPENCODE_CONFIG is set
    assert_includes log, "OPENCODE_CONFIG="
    refute_includes log, 'OPENCODE_CONFIG=""'
  ensure
    FileUtils.rm_rf(root)
  end

  def test_opencode_config_file_is_valid_json_with_correct_shape
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, _fake_claude, fake_oc, build_dir = setup_space(root)

    mission.dispatch("demo", "A",
                     harness: "opencode",
                     model: "fireworks-ai/test-model",
                     max_turns: 77,
                     opencode_bin: fake_oc)

    config_path = File.join(build_dir, "opencode.json")
    assert File.exist?(config_path), "opencode.json must be written to build dir"

    cfg = JSON.parse(File.read(config_path))
    assert_equal 77, cfg.dig("agent", "builder", "steps")
    bash = cfg.dig("agent", "builder", "permission", "bash")
    assert_equal "deny", bash["git commit *"]
    assert_equal "deny", bash["git push *"]
    assert_equal "allow", bash["*"]
  ensure
    FileUtils.rm_rf(root)
  end

  def test_opencode_config_path_passed_via_env
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, _fake_claude, fake_oc, build_dir = setup_space(root)

    mission.dispatch("demo", "A",
                     harness: "opencode",
                     model: "fireworks-ai/test-model",
                     opencode_bin: fake_oc)

    log = File.read(File.join(build_dir, "run.jsonl"))
    expected_config = File.join(build_dir, "opencode.json")
    assert_includes log, expected_config
  ensure
    FileUtils.rm_rf(root)
  end

  # ── Footgun guard ─────────────────────────────────────────────────────────

  def test_footgun_guard_raises_when_opencode_with_default_model
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, _fake_claude, _fake_oc, _build_dir = setup_space(root)

    assert_raises(SpaceArchitect::Error) do
      mission.dispatch("demo", "A", harness: "opencode")
    end
  ensure
    FileUtils.rm_rf(root)
  end

  def test_footgun_guard_allows_opencode_with_explicit_model
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, _fake_claude, fake_oc, _build_dir = setup_space(root)

    # Should not raise — explicit non-claude model
    res = mission.dispatch("demo", "A",
                           harness: "opencode",
                           model: "fireworks-ai/some-model",
                           opencode_bin: fake_oc)
    assert_kind_of Hash, res
  ensure
    FileUtils.rm_rf(root)
  end

  def test_harness_factory_raises_on_unknown_harness
    assert_raises(SpaceArchitect::Error) do
      SpaceArchitect::Harness.for("unknown-harness",
                                  model: "x", max_turns: 1, config_dir: Dir.mktmpdir)
    end
  end
end
