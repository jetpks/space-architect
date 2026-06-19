# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class ArchitectCLITest < SpaceCadetTest
  # Build a real git-backed space in a temp dir so architect commands can commit.
  # Does not go through `space new` (which uses Async::Process). Instead writes
  # .space.yml and calls the real git binary directly.
  def create_real_space(base_dir, id: "20260619-test-space", title: "Test Space", repos: [])
    spaces_dir = File.join(base_dir, "src", "spaces")
    FileUtils.mkdir_p(spaces_dir)
    space_dir = File.join(spaces_dir, id)
    FileUtils.mkdir_p(File.join(space_dir, "artifacts"))
    FileUtils.mkdir_p(File.join(space_dir, "repos"))
    FileUtils.mkdir_p(File.join(space_dir, "tmp"))

    data = {
      "version" => 1, "id" => id, "title" => title, "status" => "active",
      "created_at" => "2026-06-19T00:00:00Z", "updated_at" => "2026-06-19T00:00:00Z",
      "repos" => repos, "notes" => [], "tickets" => [], "tags" => []
    }
    File.write(File.join(space_dir, ".space.yml"), YAML.dump(data))

    system("git", "-C", space_dir, "init", "-q", "-b", "main",
      exception: false) ||
      system("git", "-C", space_dir, "init", "-q")
    system("git", "-C", space_dir, "config", "user.name", "Test Builder")
    system("git", "-C", space_dir, "config", "user.email", "test@example.com")
    system("git", "-C", space_dir, "add", ".space.yml")
    system("git", "-C", space_dir, "commit", "-q", "-m", "init")

    Pathname.new(space_dir)
  end

  # Create a bare repo in repos/<name> with one commit so worktrees work.
  def create_real_repo(space_path, name)
    repo_dir = File.join(space_path, "repos", name)
    FileUtils.mkdir_p(repo_dir)
    system("git", "-C", repo_dir, "init", "-q", "-b", "main",
      exception: false) ||
      system("git", "-C", repo_dir, "init", "-q")
    system("git", "-C", repo_dir, "config", "user.name", "Test Builder")
    system("git", "-C", repo_dir, "config", "user.email", "test@example.com")
    File.write(File.join(repo_dir, "README.md"), "# #{name}\n")
    system("git", "-C", repo_dir, "add", "README.md")
    system("git", "-C", repo_dir, "commit", "-q", "-m", "init #{name}")
    repo_dir
  end

  # ── GA1 smoke: init and status exit 0 ──────────────────────────────────────

  def test_architect_init_creates_artifacts_and_yml_block
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        out, err = invoke("architect", "init")

        assert_empty err
        assert_match(/Mission ready/, out)
        assert_path_exists File.join(space_path, "artifacts", "HANDOFF.md")
        assert_path_exists File.join(space_path, "artifacts", "gates", ".gitkeep")
        assert_path_exists File.join(space_path, "artifacts", "lanes", ".gitkeep")
        assert_path_exists File.join(space_path, "artifacts", "prd", ".gitkeep")

        yml = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        assert_equal "active", yml.dig("architect", "status")
        assert_equal [], yml.dig("architect", "slices")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_architect_status_exits_0_after_init
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("architect", "init")
        out, err = invoke("architect", "status")

        assert_empty err
        assert_match(/Mission status/, out)
        assert_match(/active/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_architect_init_is_idempotent_warns_on_second_call
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("architect", "init")
        _out, err = invoke("architect", "init")
        assert_match(/already exists/, err)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── GA3: freeze records SHA, refuses re-freeze after gate changed ──────────

  def test_freeze_records_sha_and_refuses_re_freeze_after_gate_changed # GA3
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("architect", "init")

        # Create a gate file
        gate_path = File.join(space_path, "artifacts", "gates", "slice-1.md")
        File.write(gate_path, "# Gates for slice-1\n\nGA1: tests green\n")

        # First freeze — should succeed
        out, err = invoke("architect", "freeze", "slice-1")
        assert_empty err
        assert_match(/[0-9a-f]{7,40}/, out)

        # .space.yml should record freeze_sha
        yml = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        slice_entry = yml.dig("architect", "slices")&.find { |s| s["name"] == "slice-1" }
        refute_nil slice_entry, "slice entry should be recorded"
        freeze_sha = slice_entry["freeze_sha"]
        refute_nil freeze_sha
        assert_match(/\A[0-9a-f]{40}\z/, freeze_sha)
        assert_equal "slice-1", yml.dig("architect", "current_slice")

        # Modify the gate file
        File.write(gate_path, "# Gates for slice-1 — MODIFIED\n")

        # Re-freeze should be refused (exit via handle_errors → err)
        _out2, err2 = invoke("architect", "freeze", "slice-1")
        refute_empty err2
        assert_match(/refusing to re-freeze/i, err2)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_architect_block_survives_unrelated_space_command # GA3 round-trip
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("architect", "init")

        yml_before = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        architect_before = yml_before["architect"]
        refute_nil architect_before

        # Run an unrelated command that modifies .space.yml
        invoke("status", "done")

        yml_after = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        assert_equal "done", yml_after["status"], "status should be updated"
        assert_equal architect_before, yml_after["architect"], "architect: block must survive round-trip"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # ── GA4: verify reports FAIL/PASS correctly ───────────────────────────────

  def test_verify_reports_fail_when_builder_commit_exists # GA4
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("architect", "init")

        # Create and freeze a gate
        File.write(File.join(space_path, "artifacts", "gates", "s1.md"), "# Gates\n")
        invoke("architect", "freeze", "s1")

        # Add a worktree for the lane
        invoke("architect", "worktree", "add", "my-repo", "s1", "lane-a")

        wt_path = File.join(space_path, "tmp", "architect", "wt", "s1-lane-a")
        assert_path_exists wt_path

        # Builder makes a commit in the worktree
        File.write(File.join(wt_path, "builder_work.md"), "# builder commit\n")
        system("git", "-C", wt_path, "add", "builder_work.md")
        system("git", "-C", wt_path, "commit", "-q", "-m", "builder commit")

        out, err = invoke("architect", "verify", "s1")
        assert_empty err
        # (b) should FAIL because there's a builder commit
        assert_match(/FAIL/, out)
        # Specifically check (b) is FAIL
        rows = out.lines.select { |l| l.include?("builder commits") }
        assert rows.any? { |r| r.include?("FAIL") }, "expected (b) no builder commits to be FAIL"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_verify_reports_fail_when_lane_report_missing # GA4
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("architect", "init")

        File.write(File.join(space_path, "artifacts", "gates", "s1.md"), "# Gates\n")
        invoke("architect", "freeze", "s1")
        invoke("architect", "worktree", "add", "my-repo", "s1", "lane-b")

        out, err = invoke("architect", "verify", "s1")
        assert_empty err
        # (c) lane report missing → FAIL
        rows = out.lines.select { |l| l.include?("lane report") }
        assert rows.any? { |r| r.include?("FAIL") }, "expected (c) lane report exists to be FAIL"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_verify_reports_pass_when_clean # GA4
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("architect", "init")

        File.write(File.join(space_path, "artifacts", "gates", "s1.md"), "# Gates\n")
        invoke("architect", "freeze", "s1")
        invoke("architect", "worktree", "add", "my-repo", "s1", "lane-c")

        # Write the lane report (non-empty)
        report_path = File.join(space_path, "artifacts", "lanes", "s1-lane-c.md")
        File.write(report_path, "# Lane Report\nSTATUS: COMPLETE\n")

        out, err = invoke("architect", "verify", "s1")
        assert_empty err

        # (a), (b), (c) should all PASS (gates untouched, no builder commits, report present)
        refute_match(/FAIL/, out, "expected all checks to PASS, got:\n#{out}")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end
end
