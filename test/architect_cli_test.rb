# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class ArchitectCLITest < Space::ArchitectTest
  # Build a real git-backed space in a temp dir so architect commands can commit.
  # Does not go through `space new` (which uses Async::Process). Instead writes
  # space.yaml and calls the real git binary directly.
  def create_real_space(base_dir, id: "20260619-test-space", title: "Test Space", repos: [])
    spaces_dir = File.join(base_dir, "architect", "spaces")
    FileUtils.mkdir_p(spaces_dir)
    space_dir = File.join(spaces_dir, id)
    FileUtils.mkdir_p(File.join(space_dir, "architecture"))
    FileUtils.mkdir_p(File.join(space_dir, "repos"))
    FileUtils.mkdir_p(File.join(space_dir, "tmp"))

    data = {
      "version" => 1, "id" => id, "title" => title, "status" => "active",
      "created_at" => "2026-06-19T00:00:00Z", "updated_at" => "2026-06-19T00:00:00Z",
      "repos" => repos, "notes" => [], "tickets" => [], "tags" => []
    }
    yaml = YAML.dump(data)
    File.write(File.join(space_dir, "space.yaml"), yaml)
    FileUtils.cp_r(File.join(Space::GitFixtureTemplate.space_dir(yaml), ".git"), space_dir)

    Pathname.new(space_dir)
  end

  # Create a repo in repos/<name> with one commit so worktrees work.
  def create_real_repo(space_path, name)
    repo_dir = File.join(space_path, "repos", name)
    FileUtils.mkdir_p(repo_dir)
    FileUtils.cp_r(File.join(Space::GitFixtureTemplate.repo_dir, ".git"), repo_dir)
    File.write(File.join(repo_dir, "README.md"), "# #{name}\n")
    repo_dir
  end

  # ── init / status smoke ─────────────────────────────────────────────────────

  def test_architect_init_creates_handoff_and_yml_block
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        out, err = invoke("init")

        assert_empty err
        assert_match(/Project ready/, out)
        assert_path_exists File.join(space_path, "architecture", "ARCHITECT.md")
        assert_path_exists File.join(space_path, ".claude", "settings.json"),
          "init must scaffold .claude/settings.json with the SessionStart hook"
        # One-file model: no gates/lanes/prd scaffolding.
        refute_path_exists File.join(space_path, "architecture", "gates")
        refute_path_exists File.join(space_path, "architecture", "lanes")
        refute_path_exists File.join(space_path, "architecture", "prd")

        yml = YAML.safe_load(File.read(File.join(space_path, "space.yaml")), aliases: false)
        assert_equal "active", yml.dig("project", "status")
        assert_equal [], yml.dig("project", "iterations")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_architect_status_exits_0_after_init
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")
        out, err = invoke("status")

        assert_empty err
        assert_match(/Project status/, out)
        assert_match(/active/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # init is idempotent: second call does not raise, does not error, leaves
  # ARCHITECT.md and settings.json untouched (new behavior since I10).
  def test_architect_init_is_idempotent_warns_on_second_call
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")
        out, err = invoke("init")

        assert_empty err, "second init must not error"
        assert_match(/Project ready/, out, "second init must still confirm readiness")
        assert_path_exists File.join(space_path, "architecture", "ARCHITECT.md"),
          "ARCHITECT.md must still be present after second init"
        assert_path_exists File.join(space_path, ".claude", "settings.json"),
          "settings.json must still be present after second init"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── ground: emits grounding reads to stdout ────────────────────────────────────

  def test_architect_ground_emits_grounding_reads
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")
        invoke("brief", "new")
        invoke("new", "my-iter")

        out, err = invoke("ground")

        assert_empty err
        assert_match(/=== architecture\/ARCHITECT\.md ===/, out)
        assert_match(/=== architecture\/BRIEF\.md ===/, out)
        assert_match(/=== architecture\/I01-my-iter\.md ===/, out)
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ground with no iteration files yet: emits ARCHITECT.md only (no error).
  def test_architect_ground_with_no_iteration_emits_architect_md_only
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")

        out, err = invoke("ground")

        assert_empty err
        assert_match(/=== architecture\/ARCHITECT\.md ===/, out)
        refute_match(/=== architecture\/BRIEF\.md ===/, out)
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── new: scaffolds architecture/I<NN>-<iteration>.md and records the iteration ──────────

  def test_architect_new_scaffolds_ordinal_slice_file
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")

        out1, err1 = invoke("new", "first-slice")
        assert_empty err1
        assert_match(/Iteration scaffolded/, out1)
        assert_path_exists File.join(space_path, "architecture", "I01-first-slice.md")

        # second iteration gets the next ordinal
        invoke("new", "second-slice")
        assert_path_exists File.join(space_path, "architecture", "I02-second-slice.md")

        slice_text = File.read(File.join(space_path, "architecture", "I01-first-slice.md"))
        assert_match(/^# I01: first-slice/, slice_text)
        assert_match(/^## Acceptance Criteria/, slice_text)
        assert_match(/^## Builder Prompt/, slice_text)

        yml = YAML.safe_load(File.read(File.join(space_path, "space.yaml")), aliases: false)
        entry = yml.dig("project", "iterations").find { |s| s["name"] == "first-slice" }
        refute_nil entry
        assert_equal 1, entry["ordinal"]
        assert_equal "architecture/I01-first-slice.md", entry["file"]
        # `new` makes the freshly-created iteration current.
        assert_equal "second-slice", yml.dig("project", "current_iteration")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── freeze: records SHA, refuses re-freeze after a frozen section changes ───

  def test_freeze_records_sha_and_guards_frozen_region
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "slice-1")
        slice_file = File.join(space_path, "architecture", "I01-slice-1.md")

        # First freeze — the scaffold already carries a "## Acceptance Criteria" section.
        out, err = invoke("freeze", "slice-1")
        assert_empty err
        assert_match(/[0-9a-f]{7,40}/, out)

        yml = YAML.safe_load(File.read(File.join(space_path, "space.yaml")), aliases: false)
        entry = yml.dig("project", "iterations").find { |s| s["name"] == "slice-1" }
        freeze_sha = entry["freeze_sha"]
        assert_match(/\A[0-9a-f]{40}\z/, freeze_sha)
        assert_equal "slice-1", yml.dig("project", "current_iteration")

        # Appending BELOW the freeze boundary (Builder Prompt) is allowed —
        # re-freeze returns the same sha, no error.
        File.write(slice_file, File.read(slice_file) + "\n### Lane A\nsome dispatched prompt\n")
        out2, err2 = invoke("freeze", "slice-1")
        assert_empty err2
        assert_match(/#{freeze_sha[0, 7]}/, out2)

        # Changing a FROZEN section (Acceptance Criteria) is refused.
        text = File.read(slice_file)
        text = text.sub("## Acceptance Criteria", "## Acceptance Criteria\n\nGA9: tampered threshold")
        File.write(slice_file, text)
        _out3, err3 = invoke("freeze", "slice-1")
        refute_empty err3
        assert_match(/refusing to re-freeze/i, err3)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_freeze_refuses_slice_without_rubric
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "no-rubric")
        slice_file = File.join(space_path, "architecture", "I01-no-rubric.md")
        File.write(slice_file, "# I01: no-rubric\n\n## Specification\n\njust a contract\n")

        _out, err = invoke("freeze", "no-rubric")
        assert_match(/no '## Acceptance Criteria' section/, err)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_architect_block_survives_unrelated_space_command
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")

        yml_before = YAML.safe_load(File.read(File.join(space_path, "space.yaml")), aliases: false)
        architect_before = yml_before["project"]
        refute_nil architect_before

        invoke("space", "status", "done")

        yml_after = YAML.safe_load(File.read(File.join(space_path, "space.yaml")), aliases: false)
        assert_equal "done", yml_after["status"], "status should be updated"
        assert_equal architect_before, yml_after["project"], "architect: block must survive round-trip"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── verify: reports per-lane PASS/FAIL ──────────────────────────────────────

  def test_verify_reports_fail_when_builder_commit_exists
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-a")

        wt_path = File.join(space_path, "build", "I01-s1-lane-a", "wt")
        assert_path_exists wt_path

        File.write(File.join(wt_path, "builder_work.md"), "# builder commit\n")
        system("git", "-C", wt_path, "add", "builder_work.md")
        system("git", "-C", wt_path, "commit", "-q", "-m", "builder commit")

        out, err = invoke("verify", "s1")
        assert_empty err
        rows = out.lines.select { |l| l.include?("builder commits") }
        assert rows.any? { |r| r.include?("FAIL") }, "expected (b) no builder commits to be FAIL"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_verify_reports_fail_when_scratch_report_missing
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-b")

        out, err = invoke("verify", "s1")
        assert_empty err
        rows = out.lines.select { |l| l.include?("scratch report") }
        assert rows.any? { |r| r.include?("FAIL") }, "expected (c) scratch report exists to be FAIL"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # AC6: architect status surfaces harness and model for each lane
  def test_status_shows_lane_harness_and_model
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("worktree", "add", "my-repo", "demo", "lane-a",
               "--harness", "opencode", "--model", "fireworks-ai/test-model")

        out, err = invoke("status")
        assert_empty err
        assert_includes out, "opencode"
        assert_includes out, "fireworks-ai/test-model"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # AC6: architect status marks variant set with "variant:" prefix;
  #      non-variant lane renders without prefix (control assertion)
  def test_status_marks_variant_set_and_leaves_non_variant_unchanged
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")

        # Iteration with a variant set
        invoke("new", "variant-iter")
        invoke("variant", "add", "my-repo", "variant-iter",
               "--pairs", "claude-code,opencode:fireworks-ai/accounts/fireworks/models/glm-5p2")

        # Iteration with a plain non-variant lane (control)
        invoke("new", "plain-iter")
        invoke("worktree", "add", "my-repo", "plain-iter", "lane-a",
               "--harness", "claude-code")

        out, err = invoke("status")
        assert_empty err

        variant_row = out.lines.find { |l| l.include?("variant-iter") }
        refute_nil variant_row, "expected a row for variant-iter"
        assert_includes variant_row, "variant:", "variant-iter row must include 'variant:' prefix"
        assert_includes variant_row, "claude-code"
        assert_includes variant_row, "glm-5p2"

        plain_row = out.lines.find { |l| l.include?("plain-iter") }
        refute_nil plain_row, "expected a row for plain-iter"
        refute_includes plain_row, "variant:", "plain-iter row must NOT include 'variant:' prefix"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_dispatch_cli_runs_fake_claude_and_writes_run_jsonl
    setup = temp_env
    env = setup.fetch(:env)

    fake = File.join(setup[:root], "fake_claude")
    File.write(fake, <<~RUBY)
      #!/usr/bin/env ruby
      a = ARGV; c = Dir.pwd; s = $stdin.gets
      $stdout.puts "argv=" + a.inspect
      $stdout.puts "cwd=" + c.inspect
      $stdout.puts "stdin=" + (s || "").chomp
      $stdout.flush
      exit 0
    RUBY
    File.chmod(0o755, fake)

    with_env(env.merge("ARCHITECT_CLAUDE_BIN" => fake)) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("worktree", "add", "my-repo", "demo", "A")

        build_dir = File.join(space_path, "build", "I01-demo-A")
        FileUtils.mkdir_p(build_dir)
        File.write(File.join(build_dir, "prompt.md"), "test prompt\n")

        out, err = invoke("dispatch", "demo", "A")

        assert_empty err
        assert_match(/Builder exited with status 0/, out)
        assert File.exist?(File.join(build_dir, "run.jsonl")), "run.jsonl must be created"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── dispatch --detach: exits 0 immediately, prints PID + paths ───────────────

  def test_dispatch_cli_detach_flag_returns_immediately_exit_zero
    setup = temp_env
    env = setup.fetch(:env)

    # Fake builder that sleeps briefly — with --detach the CLI must return before it finishes
    fake = File.join(setup[:root], "fake_detach_claude")
    File.write(fake, <<~RUBY)
      #!/usr/bin/env ruby
      $stdout.puts "child_pid=\#{Process.pid}"
      $stdout.flush
      sleep 0.3
      $stdout.puts "done"
      $stdout.flush
      exit 0
    RUBY
    File.chmod(0o755, fake)

    with_env(env.merge("ARCHITECT_CLAUDE_BIN" => fake)) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("worktree", "add", "my-repo", "demo", "A")

        build_dir = File.join(space_path, "build", "I01-demo-A")
        FileUtils.mkdir_p(build_dir)
        File.write(File.join(build_dir, "prompt.md"), "test prompt\n")

        t0 = Time.now
        out, err = invoke("dispatch", "demo", "A", "--detach")
        elapsed = Time.now - t0

        assert_empty err
        # Exits 0 (launched successfully)
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        # Output includes PID
        assert_match(/PID:\s+\d+/, out, "output must include PID")
        # Output includes run.jsonl path
        assert_includes out, "run.jsonl"
        # Output includes report.md path
        assert_includes out, "report.md"
        # Output includes detach confirmation
        assert_match(/[Dd]ispatched detached/, out)
        # Returned before the fake builder finished (builder sleeps 0.3s)
        assert elapsed < 0.1, "dispatch --detach should return immediately (took #{elapsed.round(3)}s)"

        # No "Builder exited with status" line (that's the blocking path)
        refute_match(/Builder exited/, out)
      end
    end
  ensure
    sleep 0.35 # let any lingering child exit
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # Without --detach: existing behavior unchanged ("Builder exited with status N")
  def test_dispatch_cli_no_detach_flag_is_blocking_and_unchanged
    setup = temp_env
    env = setup.fetch(:env)

    fake = File.join(setup[:root], "fake_blocking_claude")
    File.write(fake, <<~RUBY)
      #!/usr/bin/env ruby
      a = ARGV; c = Dir.pwd; s = $stdin.gets
      $stdout.puts "argv=" + a.inspect
      $stdout.puts "cwd=" + c.inspect
      $stdout.puts "stdin=" + (s || "").chomp
      $stdout.flush
      exit 0
    RUBY
    File.chmod(0o755, fake)

    with_env(env.merge("ARCHITECT_CLAUDE_BIN" => fake)) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("worktree", "add", "my-repo", "demo", "A")

        build_dir = File.join(space_path, "build", "I01-demo-A")
        FileUtils.mkdir_p(build_dir)
        File.write(File.join(build_dir, "prompt.md"), "test prompt\n")

        out, err = invoke("dispatch", "demo", "A")

        assert_empty err
        assert_match(/Builder exited with status 0/, out)
        refute_match(/Dispatched detached/, out)
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_verify_reports_pass_when_clean
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-c")

        # The builder's scratch report (non-empty) lives in build/.
        FileUtils.mkdir_p(File.join(space_path, "build", "I01-s1-lane-c"))
        File.write(File.join(space_path, "build", "I01-s1-lane-c", "report.md"),
          "# Lane Report\nSTATUS: COMPLETE\n")

        out, err = invoke("verify", "s1")
        assert_empty err
        refute_match(/FAIL/, out, "expected all checks to PASS, got:\n#{out}")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # AC5: architect status shows the winner marker for a promoted variant iteration,
  #      and a non-promoted variant iteration renders without the marker (control)
  def test_status_shows_winner_marker_for_promoted_variant
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")

        # Promoted variant iteration
        invoke("new", "winner-iter")
        invoke("variant", "add", "my-repo", "winner-iter",
               "--pairs", "claude-code,opencode:fireworks-ai/accounts/fireworks/models/glm-5p2")
        invoke("variant", "promote", "winner-iter", "v02")

        # Non-promoted variant iteration (control)
        invoke("new", "control-iter")
        invoke("variant", "add", "my-repo", "control-iter",
               "--pairs", "claude-code,opencode:fireworks-ai/accounts/fireworks/models/glm-5p2")

        out, err = invoke("status")
        assert_empty err

        promoted_row = out.lines.find { |l| l.include?("winner-iter") && l.include?("my-repo") }
        refute_nil promoted_row, "expected a table row for winner-iter"
        assert_includes promoted_row, "variant:", "winner-iter row must include 'variant:' prefix"
        assert_includes promoted_row, " → winner: v02", "winner-iter row must include winner marker"
        assert_includes promoted_row, "claude-code"
        assert_includes promoted_row, "glm-5p2"

        unpromoted_row = out.lines.find { |l| l.include?("control-iter") && l.include?("my-repo") }
        refute_nil unpromoted_row, "expected a table row for control-iter"
        assert_includes unpromoted_row, "variant:", "control-iter row must include 'variant:' prefix"
        refute_includes unpromoted_row, " → winner:", "control-iter row must NOT include winner marker"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # variant promote CLI: prints confirmation, surfaces errors via handle_errors
  def test_variant_promote_cli_prints_confirmation
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("variant", "add", "my-repo", "demo",
               "--pairs", "claude-code,opencode:fireworks-ai/accounts/fireworks/models/glm-5p2")

        out, err = invoke("variant", "promote", "demo", "v02")
        assert_empty err
        assert_match(/Promoted v02/, out)
        assert_match(/discarded: v01/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── I05: effort status render and CLI options ──────────────────────────────

  # AC6: lane with effort renders ·<effort> suffix; lane without renders byte-identical to pre-I05
  def test_status_shows_effort_suffix_for_effort_lane
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("worktree", "add", "my-repo", "demo", "lane-e",
               "--harness", "opencode",
               "--model", "fireworks-ai/accounts/fireworks/models/glm-5p2",
               "--effort", "high")
        invoke("worktree", "add", "my-repo", "demo", "lane-f",
               "--harness", "opencode",
               "--model", "fireworks-ai/accounts/fireworks/models/glm-5p2")

        out, err = invoke("status")
        assert_empty err

        # lane-e cell has ·high inside the per-lane paren, after the model
        assert_includes out, "lane-e(my-repo·opencode·fireworks-ai/accounts/fireworks/models/glm-5p2·high)",
          "expected lane-e cell with ·high inside the paren"
        # lane-f cell does NOT carry effort (closes right after the model)
        assert_includes out, "lane-f(my-repo·opencode·fireworks-ai/accounts/fireworks/models/glm-5p2)",
          "expected lane-f cell without effort"
        refute_includes out, "lane-f(my-repo·opencode·fireworks-ai/accounts/fireworks/models/glm-5p2·high)",
          "lane-f cell must not carry ·high"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # AC6 control: worktree add without effort → CLI passes effort: nil → no effort key in yaml
  def test_worktree_add_cli_without_effort_produces_no_effort_key
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("worktree", "add", "my-repo", "demo", "lane-a",
               "--harness", "opencode",
               "--model", "fireworks-ai/accounts/fireworks/models/glm-5p2")

        yml = YAML.safe_load(File.read(File.join(space_path, "space.yaml")), aliases: false)
        lane = yml.dig("project", "iterations", 0, "lanes", 0)
        refute lane.key?("effort"), "no effort key expected when --effort not passed"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_variant_promote_cli_surfaces_error_for_bad_winner
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("variant", "add", "my-repo", "demo",
               "--pairs", "claude-code,opencode:fireworks-ai/accounts/fireworks/models/glm-5p2")

        _out, err = invoke("variant", "promote", "demo", "v99")
        refute_empty err
        assert_match(/v99/, err)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # AC3: variant compare CLI renders a side-by-side table with winner/discarded
  #      statuses, (default) for nil-model, - for nil-effort, and exit code 0
  def test_variant_compare_cli_renders_table_with_statuses
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("variant", "add", "my-repo", "demo",
               "--pairs", "claude-code,opencode:fireworks-ai/accounts/fireworks/models/glm-5p2")
        invoke("variant", "promote", "demo", "v02")

        out, err = invoke("variant", "compare", "demo")
        assert_empty err
        assert_match(/Variant comparison: demo/, out)
        assert_match(/Winner: v02/, out)

        # winner row Status cell reads WINNER
        v02_line = out.lines.find { |l| l.include?("v02") && l.include?("WINNER") }
        refute_nil v02_line, "expected a table row for v02 with WINNER status"

        # non-winner variant row Status cell reads discarded
        v01_line = out.lines.find { |l| l.include?("v01") && l.include?("discarded") }
        refute_nil v01_line, "expected a table row for v01 with discarded status"

        # nil-model lane's Model cell reads (default)
        assert_includes v01_line, "(default)"

        # lane with no effort renders - in the Effort cell (between Model and Status)
        assert_match(/\(default\)\s+-\s+discarded/, v01_line)

        # exit code 0
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── section / evidence / brief / freeze-prints-AC / integrate ───────────────

  def test_section_cli_writes_and_commits_from_body
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")

        out, err = invoke("section", "s1", "specification", "--body", "- Objective — the seam (BRIEF §3.1)")
        assert_empty err
        assert_match(/Committed ## Specification/, out)

        text = File.read(File.join(space_path, "architecture", "I01-s1.md"))
        assert_match(/the seam \(BRIEF §3\.1\)/, text)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_freeze_cli_prints_frozen_acceptance_criteria
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")

        slice = File.join(space_path, "architecture", "I01-s1.md")
        text = File.read(slice).sub(/(\|-----\|---------\|-----------\|---------\|\n)/,
          "\\1| G0 | `rake test` | green | §1 |\n")
        File.write(slice, text)

        out, err = invoke("freeze", "s1")
        assert_empty err
        assert_match(/Frozen Acceptance Criteria/, out)
        assert_match(/rake test/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_evidence_cli_transcribes_report_and_surfaces_status
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-a")

        FileUtils.mkdir_p(File.join(space_path, "build", "I01-s1-lane-a"))
        File.write(File.join(space_path, "build", "I01-s1-lane-a", "report.md"),
          "raw numbers\nSTATUS: COMPLETE\n")

        out, err = invoke("evidence", "s1", "--lane", "lane-a")
        assert_empty err
        assert_match(/Builder STATUS: STATUS: COMPLETE/, out)

        text = File.read(File.join(space_path, "architecture", "I01-s1.md"))
        assert_includes text, "raw numbers"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_brief_new_cli_scaffolds_brief
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("init")
        out, err = invoke("brief", "new")
        assert_empty err
        assert_match(/Brief ready/, out)
        assert_path_exists File.join(space_path, "architecture", "BRIEF.md")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_integrate_cli_merges_clean_lane
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-a")

        wt = File.join(space_path, "build", "I01-s1-lane-a", "wt")
        File.write(File.join(wt, "feature.rb"), "def feature; end\n")

        out, err = invoke("integrate", "s1", "--lanes", "lane-a")
        assert_empty err
        assert_match(%r{Merged lane-a → project/test-space}, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # land prints gh pr create command for integrated repos; raises clear error when nothing integrated.
  def test_land_cli_generates_pr_command
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-a")

        wt = File.join(space_path, "build", "I01-s1-lane-a", "wt")
        File.write(File.join(wt, "feature.rb"), "def feature; end\n")
        invoke("integrate", "s1", "--lanes", "lane-a")

        out, err = invoke("land")
        assert_empty err
        assert_match(/gh pr create --base main/, out)
        assert_match(/project\/test-space/, out)
        body_file = File.join(space_path, "build", "land", "my-repo-pr-body.md")
        assert_path_exists body_file
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # I06: --push-url and --push-token CLI options are accepted and the push
  # endpoint receives the builder's stdout.
  def test_dispatch_cli_push_url_and_push_token_options
    setup = temp_env
    env = setup.fetch(:env)

    require "socket"

    received_chunks = []
    tcp_server = TCPServer.new("127.0.0.1", 0)
    port = tcp_server.addr[1]

    server_thread = Thread.new do
      client = tcp_server.accept
      # Drain request line + headers
      while (line = client.gets) && !line.chomp.empty?; end
      # Read chunked body
      loop do
        size_line = client.gets&.strip || ""
        size = size_line.to_i(16)
        break if size == 0
        chunk = client.read(size)
        received_chunks << chunk
        client.read(2)  # trailing CRLF after chunk data
      end
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    rescue
      # ignore connection errors
    ensure
      client&.close
      tcp_server.close
    end

    fake = File.join(setup[:root], "fake_claude_push")
    File.write(fake, <<~RUBY)
      #!/usr/bin/env ruby
      a = ARGV; c = Dir.pwd; s = $stdin.gets
      $stdout.puts "argv=" + a.inspect
      $stdout.puts "cwd=" + c.inspect
      $stdout.puts "stdin=" + (s || "").chomp
      $stdout.flush
      exit 0
    RUBY
    File.chmod(0o755, fake)

    with_env(env.merge("ARCHITECT_CLAUDE_BIN" => fake)) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("worktree", "add", "my-repo", "demo", "A")

        build_dir = File.join(space_path, "build", "I01-demo-A")
        FileUtils.mkdir_p(build_dir)
        File.write(File.join(build_dir, "prompt.md"), "push test prompt\n")

        out, err = invoke("dispatch", "demo", "A",
                          "--push-url", "http://127.0.0.1:#{port}/runs/r1/ingest",
                          "--push-token", "test-bearer-token")

        assert_empty err
        assert_match(/Builder exited with status 0/, out)

        log = File.read(File.join(build_dir, "run.jsonl"))
        assert_includes log, "--include-partial-messages", "partial-messages flag must be in log"
      end
    end

    server_thread.join(5)
    assert received_chunks.any? { |c| c.include?("argv=") },
      "HTTP server must receive builder output, got: #{received_chunks.inspect}"
  ensure
    tcp_server.close rescue nil
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # I09: --push-host and --push-url are mutually exclusive; the CLI forwards
  # --push-host to project.dispatch and the error surfaces via handle_errors.
  def test_dispatch_cli_push_host_and_push_url_mutual_exclusion
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")
        invoke("worktree", "add", "my-repo", "demo", "A")

        build_dir = File.join(space_path, "build", "I01-demo-A")
        FileUtils.mkdir_p(build_dir)
        File.write(File.join(build_dir, "prompt.md"), "test\n")

        _out, err = invoke("dispatch", "demo", "A",
                           "--push-host",  "http://example.com",
                           "--push-url",   "http://example.com/runs/1/ingest",
                           "--push-token", "tok")

        assert_match(/push-host|push-url/i, err,
                     "expected mutual-exclusion error to mention push-host or push-url")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── gate: PASS/FAIL rendering and exit-code signalling ────────────────────

  def test_gate_command_reports_pass_and_exits_zero
    setup = temp_env
    env   = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")

        # Inject a passing gate and freeze
        slice = File.join(space_path, "architecture", "I01-demo.md")
        text  = File.read(slice)
        gate_yaml = <<~YAML
          - id: echo-pass
            ac: AC1
            cmd: echo gate-ok
            expect:
              exit_code: 0
        YAML
        text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
        File.write(slice, text)
        invoke("freeze", "demo")
        invoke("worktree", "add", "my-repo", "demo", "lane-a")

        out, err = invoke("gate", "demo", "lane-a")

        assert_empty err
        assert_match(/PASS/, out, "passing gate must show PASS")
        assert_match(/necessary, not sufficient/, out, "necessary-not-sufficient framing must be present")
        refute_match(/FAIL/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_gate_command_reports_fail_and_exits_nonzero
    setup = temp_env
    env   = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "demo")

        slice = File.join(space_path, "architecture", "I01-demo.md")
        text  = File.read(slice)
        gate_yaml = <<~YAML
          - id: echo-fail
            ac: AC1
            cmd: sh -c 'exit 1'
            expect:
              exit_code: 0
        YAML
        text = text.sub(/^```gates\n.*?^```/m, "```gates\n#{gate_yaml}```")
        File.write(slice, text)
        invoke("freeze", "demo")
        invoke("worktree", "add", "my-repo", "demo", "lane-a")

        out_io  = StringIO.new
        err_io  = StringIO.new
        rc = Space::Architect::CLI.call(["gate", "demo", "lane-a"], out_io, err_io)
        out = out_io.string

        assert_equal 1, rc, "failing gate must exit non-zero"
        assert_match(/FAIL/, out, "failing gate must show FAIL")
        assert_match(/exit_code/, out, "reason must appear in output")
        assert_match(/necessary, not sufficient/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # Fix (2): no touch_set recorded → (d) in-bounds shows WARN, not FAIL or N/A.
  def test_verify_warns_when_no_touch_set_recorded
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-e")

        out, err = invoke("verify", "s1")
        assert_empty err
        rows = out.lines.select { |l| l.include?("in-bounds") }
        assert rows.any? { |r| r.include?("WARN") },
          "expected (d) in-bounds to show WARN when no touch_set recorded, got:\n#{out}"
        assert rows.none? { |r| r.include?("FAIL") },
          "WARN must not render as FAIL, got:\n#{out}"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # Fix (1): after merge_lane! commits the integrate, (b) must report PASS, not FAIL.
  def test_verify_pass_no_false_fail_after_merge_lane
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-f")

        wt_path = File.join(space_path, "build", "I01-s1-lane-f", "wt")
        File.write(File.join(wt_path, "feature.rb"), "def feature; end\n")

        FileUtils.mkdir_p(File.join(space_path, "build", "I01-s1-lane-f"))
        File.write(File.join(space_path, "build", "I01-s1-lane-f", "report.md"),
          "# Report\nSTATUS: COMPLETE\n")

        invoke("merge", "s1", "lane-f")

        out, err = invoke("verify", "s1")
        assert_empty err
        rows = out.lines.select { |l| l.include?("builder commits") }
        assert rows.any? { |r| r.include?("PASS") },
          "expected (b) to PASS after merge_lane! (integrate commit must be excluded), got:\n#{out}"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # Fix (4): verdict command records decision to space.yaml; status shows awaiting-verdict
  # before the verdict, then the decision after.
  def test_verdict_command_records_decision_and_updates_status
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("space", "init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("init")
        invoke("new", "s1")
        invoke("freeze", "s1")
        invoke("worktree", "add", "my-repo", "s1", "lane-a")

        wt_path = File.join(space_path, "build", "I01-s1-lane-a", "wt")
        File.write(File.join(wt_path, "feature.rb"), "def feature; end\n")
        invoke("merge", "s1", "lane-a")

        # After merge, before verdict: status shows awaiting-verdict
        out, = invoke("status")
        assert_includes out, "awaiting-verdict",
          "expected 'awaiting-verdict' for integrated lane with pending verdict"

        # Record the verdict
        out, err = invoke("verdict", "s1", "continue", "--body", "LGTM — gates green.")
        assert_empty err
        assert_match(/continue/i, out, "expected confirmation output to mention the decision")

        # space.yaml verdict field updated
        yml = YAML.safe_load(File.read(File.join(space_path, "space.yaml")), aliases: false)
        assert_equal "continue", yml.dig("project", "iterations", 0, "verdict"),
          "expected verdict field to be 'continue' in space.yaml"

        # status now shows the decision, not awaiting-verdict
        out, = invoke("status")
        assert_includes out, "continue"
        refute_includes out, "awaiting-verdict"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── I13: dispatch --timeout option wiring ────────────────────────────────

  # dry-cli calls exit(0) for --help, so we must test via subprocess.
  def test_dispatch_help_shows_timeout_option
    out = IO.popen(["bundle", "exec", "architect", "dispatch", "--help"],
                   err: [:child, :out]) { |f| f.read }
    assert_includes out, "--timeout", "dispatch --help must list the --timeout option"
    assert_includes out, "14400",     "dispatch --help must show the default 4h (14400s) value"
  end
end
