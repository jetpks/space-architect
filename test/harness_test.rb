# frozen_string_literal: true

require_relative "test_helper"
require "yaml"
require "json"
require "tmpdir"
require "async/http/mock"
require "async/http/client"
require "protocol/http/response"

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
    a = ARGV; c = Dir.pwd; s = $stdin.gets
    $stdout.puts "argv=" + a.inspect
    $stdout.puts "cwd=" + c.inspect
    $stdout.puts "stdin=" + (s || "").chomp
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
    # AC-fix-2: prompt arrives on stdin, not argv
    assert_includes log, "stdin=PROMPT-MARKER-99"
    argv_line = log.lines.find { |l| l.start_with?("argv=") }
    refute_includes argv_line, "PROMPT-MARKER-99"
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

  # ── Dispatch resolution from lane entry (AC3 / AC4) ──────────────────────

  # AC3: dispatch with no harness/model kwargs reads both from the persisted lane entry
  def test_dispatch_reads_harness_and_model_from_lane
    root = Dir.mktmpdir("harness-test")
    space_dir, mission, _fake_claude, fake_oc, _build_dir = setup_space(root)

    mission.worktree_add("my-repo", "demo", "B",
                         harness: "opencode",
                         model: "fireworks-ai/accounts/fireworks/models/glm-5p2")
    b_build_dir = File.join(space_dir, "build", "I01-demo-B")
    FileUtils.mkdir_p(b_build_dir)
    File.write(File.join(b_build_dir, "prompt.md"), "PROMPT-B\n")

    res = mission.dispatch("demo", "B", opencode_bin: fake_oc)
    log = File.read(File.join(b_build_dir, "run.jsonl"))

    assert_equal 0, res[:exit_code]
    # Opencode path taken — not claude path
    assert_includes log, '"run"'
    assert_includes log, '"--agent"'
    assert_includes log, '"builder"'
    # Correct model from lane
    assert_includes log, "fireworks-ai/accounts/fireworks/models/glm-5p2"
    # Claude path NOT taken
    refute_includes log, "stream-json"
  ensure
    FileUtils.rm_rf(root)
  end

  # AC4: explicit dispatch-time model overrides without mutating the persisted lane entry
  def test_dispatch_override_does_not_mutate_lane_entry
    root = Dir.mktmpdir("harness-test")
    space_dir, mission, _fake_claude, fake_oc, _build_dir = setup_space(root)

    mission.worktree_add("my-repo", "demo", "C",
                         harness: "opencode",
                         model: "original-model")
    c_build_dir = File.join(space_dir, "build", "I01-demo-C")
    FileUtils.mkdir_p(c_build_dir)
    File.write(File.join(c_build_dir, "prompt.md"), "PROMPT-C\n")

    res = mission.dispatch("demo", "C", model: "override-model", opencode_bin: fake_oc)
    log = File.read(File.join(c_build_dir, "run.jsonl"))

    assert_equal 0, res[:exit_code]
    # Captured argv carries the override model
    assert_includes log, "override-model"
    refute_includes log, "original-model"

    # Lane entry on disk is unchanged — original model survives
    yml = YAML.safe_load(File.read(File.join(space_dir, "space.yaml")), aliases: false)
    iterations = yml.dig("architect", "iterations") || []
    demo = iterations.find { |i| i["name"] == "demo" }
    lane_c = (demo["lanes"] || []).find { |l| l["name"] == "C" }
    assert_equal "original-model", lane_c["model"]
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

  # ── I07: effort → reasoningEffort config injection ───────────────────────

  # Fake binary that records argv to ARGV_RECORD_FILE (null-delimited).
  FAKE_ARGV_RECORDER = <<~RUBY
    #!/usr/bin/env ruby
    File.write(ENV.fetch("ARGV_RECORD_FILE"), ARGV.join("\x00"))
    exit 0
  RUBY

  # AC1: effort "high" + GLM model → builder_config injects reasoningEffort at correct path;
  #      agent.builder block (steps, bash permission deny map) is unchanged.
  def test_builder_config_injects_reasoning_effort_for_glm
    harness = SpaceArchitect::Harness::OpenCodeHarness.new(
      model: "fireworks-ai/accounts/fireworks/models/glm-5p2",
      max_turns: 10, bin: "opencode", config_dir: Dir.mktmpdir,
      effort: "high"
    )
    cfg = harness.builder_config

    assert_equal "high",
      cfg.dig("provider", "fireworks-ai", "models",
              "accounts/fireworks/models/glm-5p2", "options", "reasoningEffort")
    assert_equal 10,     cfg.dig("agent", "builder", "steps")
    bash = cfg.dig("agent", "builder", "permission", "bash")
    assert_equal "deny",  bash["git commit *"]
    assert_equal "deny",  bash["git push *"]
    assert_equal "allow", bash["*"]
  end

  # AC2: effort nil → builder_config returns exactly the pre-I07 hash (no "provider" key).
  def test_builder_config_no_provider_key_when_effort_nil
    harness = SpaceArchitect::Harness::OpenCodeHarness.new(
      model: "fireworks-ai/accounts/fireworks/models/glm-5p2",
      max_turns: 10, bin: "opencode", config_dir: Dir.mktmpdir
    )
    cfg = harness.builder_config
    refute cfg.key?("provider"), "builder_config must not have provider key when effort is nil: #{cfg.keys.inspect}"
    assert cfg.key?("agent")
  end

  # AC3: argv has NO --variant token whether effort is set or nil.
  def test_opencode_argv_excludes_variant_when_effort_set
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, _fake_claude, _fake_oc, _build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    ENV["ARGV_RECORD_FILE"] = argv_file
    mission.dispatch("demo", "A",
                     harness: "opencode",
                     model: "fireworks-ai/accounts/fireworks/models/glm-5p2",
                     effort: "high",
                     opencode_bin: recorder)
    recorded = File.read(argv_file).split("\x00")

    refute_includes recorded, "--variant", "no --variant token expected even with effort set: #{recorded.inspect}"
  ensure
    ENV.delete("ARGV_RECORD_FILE")
    FileUtils.rm_rf(root)
  end

  def test_opencode_argv_excludes_variant_when_no_effort
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, _fake_claude, _fake_oc, _build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    ENV["ARGV_RECORD_FILE"] = argv_file
    mission.dispatch("demo", "A",
                     harness: "opencode",
                     model: "fireworks-ai/accounts/fireworks/models/glm-5p2",
                     opencode_bin: recorder)
    recorded = File.read(argv_file).split("\x00")

    refute_includes recorded, "--variant", "no --variant token expected: #{recorded.inspect}"
    assert_equal "run", recorded[0]
    assert_includes recorded, "--format"
    assert_includes recorded, "json"
    assert_includes recorded, "--dangerously-skip-permissions"
    assert_includes recorded, "--agent"
    assert_includes recorded, "builder"
    assert_includes recorded, "--dir"
  ensure
    ENV.delete("ARGV_RECORD_FILE")
    FileUtils.rm_rf(root)
  end

  # AC4: effort "high" + Kimi model → reasoningEffort injected under Kimi's config path.
  def test_builder_config_injects_reasoning_effort_for_kimi
    harness = SpaceArchitect::Harness::OpenCodeHarness.new(
      model: "fireworks-ai/accounts/fireworks/models/kimi-k2p7-code",
      max_turns: 5, bin: "opencode", config_dir: Dir.mktmpdir,
      effort: "high"
    )
    cfg = harness.builder_config

    assert_equal "high",
      cfg.dig("provider", "fireworks-ai", "models",
              "accounts/fireworks/models/kimi-k2p7-code", "options", "reasoningEffort")
  end

  # Resolution: lane effort → injected into builder_config (no --variant in argv).
  def test_dispatch_reads_effort_from_lane
    root = Dir.mktmpdir("harness-test")
    space_dir, mission, _fake_claude, _fake_oc, _build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    mission.worktree_add("my-repo", "demo", "E",
                         harness: "opencode",
                         model: "fireworks-ai/accounts/fireworks/models/glm-5p2",
                         effort: "high")
    e_build_dir = File.join(space_dir, "build", "I01-demo-E")
    FileUtils.mkdir_p(e_build_dir)
    File.write(File.join(e_build_dir, "prompt.md"), "PROMPT-E\n")

    ENV["ARGV_RECORD_FILE"] = argv_file
    mission.dispatch("demo", "E", opencode_bin: recorder)
    recorded = File.read(argv_file).split("\x00")

    refute_includes recorded, "--variant", "lane effort must not produce --variant: #{recorded.inspect}"
    cfg = JSON.parse(File.read(File.join(e_build_dir, "opencode.json")))
    assert_equal "high",
      cfg.dig("provider", "fireworks-ai", "models",
              "accounts/fireworks/models/glm-5p2", "options", "reasoningEffort")
  ensure
    ENV.delete("ARGV_RECORD_FILE")
    FileUtils.rm_rf(root)
  end

  # Resolution: explicit effort "low" overrides lane effort "high" in generated config.
  def test_dispatch_explicit_effort_overrides_lane_effort
    root = Dir.mktmpdir("harness-test")
    space_dir, mission, _fake_claude, _fake_oc, _build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    mission.worktree_add("my-repo", "demo", "F",
                         harness: "opencode",
                         model: "fireworks-ai/accounts/fireworks/models/glm-5p2",
                         effort: "high")
    f_build_dir = File.join(space_dir, "build", "I01-demo-F")
    FileUtils.mkdir_p(f_build_dir)
    File.write(File.join(f_build_dir, "prompt.md"), "PROMPT-F\n")

    ENV["ARGV_RECORD_FILE"] = argv_file
    mission.dispatch("demo", "F", effort: "low", opencode_bin: recorder)
    recorded = File.read(argv_file).split("\x00")

    refute_includes recorded, "--variant", "no --variant expected with effort override: #{recorded.inspect}"
    cfg = JSON.parse(File.read(File.join(f_build_dir, "opencode.json")))
    assert_equal "low",
      cfg.dig("provider", "fireworks-ai", "models",
              "accounts/fireworks/models/glm-5p2", "options", "reasoningEffort")

    # Lane entry on disk still has "high" — no mutation
    yml = YAML.safe_load(File.read(File.join(space_dir, "space.yaml")), aliases: false)
    demo = yml.dig("architect", "iterations").find { |i| i["name"] == "demo" }
    lane_f = (demo["lanes"] || []).find { |l| l["name"] == "F" }
    assert_equal "high", lane_f["effort"]
  ensure
    ENV.delete("ARGV_RECORD_FILE")
    FileUtils.rm_rf(root)
  end

  # Footgun: claude-code + effort raises with opencode-only / reasoningEffort message.
  def test_harness_for_raises_for_claude_code_with_effort
    err = assert_raises(SpaceArchitect::Error) do
      SpaceArchitect::Harness.for("claude-code",
                                  model: "claude-sonnet-4-6", max_turns: 10,
                                  bin: "/fake", effort: "high")
    end
    assert_match(/opencode-only/, err.message)
    assert_match(/reasoningEffort/, err.message)
  end

  # Claude-code dispatch: no --variant in argv (unchanged by effort feature).
  def test_claude_code_dispatch_argv_unchanged_by_effort_feature
    root = Dir.mktmpdir("harness-test")
    _space_dir, mission, _fake_claude, _fake_oc, _build_dir = setup_space(root)

    recorder = File.join(root, "recorder")
    argv_file = File.join(root, "recorded_argv")
    File.write(recorder, FAKE_ARGV_RECORDER)
    File.chmod(0o755, recorder)

    ENV["ARGV_RECORD_FILE"] = argv_file
    mission.dispatch("demo", "A", claude_bin: recorder)
    recorded = File.read(argv_file).split("\x00")

    refute_includes recorded, "--variant", "claude-code argv must not contain --variant"
  ensure
    ENV.delete("ARGV_RECORD_FILE")
    FileUtils.rm_rf(root)
  end

  # ── I06: --include-partial-messages and push tee ──────────────────────────

  # AC10: --include-partial-messages appears in the spawned argv.
  def test_claude_code_harness_includes_partial_messages_in_argv
    root = Dir.mktmpdir("harness-partial")
    _space_dir, mission, fake_claude, _fake_oc, build_dir = setup_space(root)

    mission.dispatch("demo", "A", claude_bin: fake_claude)
    log = File.read(File.join(build_dir, "run.jsonl"))

    assert_includes log, "--include-partial-messages"
  ensure
    FileUtils.rm_rf(root)
  end

  # Push tee: both the log file and the HTTP server receive the same lines.
  def test_claude_code_harness_push_tee_sends_to_both_log_and_http
    root = Dir.mktmpdir("harness-push")
    space_dir, _mission, fake_claude, _fake_oc, build_dir = setup_space(root)

    wt_path      = File.join(space_dir, "build", "I01-demo-A", "wt")
    prompt_path  = File.join(build_dir, "prompt.md")
    run_log_path = File.join(build_dir, "push-run.jsonl")

    server_chunks = []
    mock_endpoint = Async::HTTP::Mock::Endpoint.new

    Sync do
      server_task = Async do
        mock_endpoint.run do |request|
          while (chunk = request.body&.read)
            server_chunks << chunk
          end
          Protocol::HTTP::Response[200, [], nil]
        end
      end

      push_client = Async::HTTP::Client.new(mock_endpoint)

      harness = SpaceArchitect::Harness::ClaudeCodeHarness.new(
        model: SpaceArchitect::Harness::CLAUDE_DEFAULT_MODEL, max_turns: 10, bin: fake_claude
      )
      harness.run(
        prompt_path:  prompt_path,
        run_log_path: run_log_path,
        chdir:        wt_path,
        push_url:     "http://localhost/runs/test-run/ingest",
        push_client:  push_client
      )

      push_client.close
      server_task.stop
    end

    log          = File.read(run_log_path)
    http_content = server_chunks.join

    assert_includes log, "argv=",          "log file must contain fake-claude output"
    assert_includes http_content, "argv=", "HTTP server must receive same content"
    assert_equal log, http_content,        "log and HTTP sink must receive identical bytes"
  ensure
    FileUtils.rm_rf(root)
  end

  # Writable body uses SizedQueue for backpressure (queue raises if maxed without pop).
  def test_protocol_http_body_writable_sized_queue_backpressure
    q    = Thread::SizedQueue.new(2)
    body = Protocol::HTTP::Body::Writable.new(queue: q)

    body.write("a")
    body.write("b")
    # Queue is full — push to a separate thread to unblock
    reader = Thread.new { [body.read, body.read] }
    body.write("c")
    body.close_write

    chunks = reader.value
    assert_equal ["a", "b"], chunks
  end
end
