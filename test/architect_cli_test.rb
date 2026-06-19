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

  # Create a repo in repos/<name> with one commit so worktrees work.
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

  # ── init / status smoke ─────────────────────────────────────────────────────

  def test_architect_init_creates_handoff_and_yml_block
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
        # One-file model: no gates/lanes/prd scaffolding.
        refute_path_exists File.join(space_path, "artifacts", "gates")
        refute_path_exists File.join(space_path, "artifacts", "lanes")
        refute_path_exists File.join(space_path, "artifacts", "prd")

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

  # ── new: scaffolds artifacts/<NN>-<slice>.md and records the slice ──────────

  def test_architect_new_scaffolds_ordinal_slice_file
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("architect", "init")

        out1, err1 = invoke("architect", "new", "first-slice")
        assert_empty err1
        assert_match(/Slice scaffolded/, out1)
        assert_path_exists File.join(space_path, "artifacts", "01-first-slice.md")

        # second slice gets the next ordinal
        invoke("architect", "new", "second-slice")
        assert_path_exists File.join(space_path, "artifacts", "02-second-slice.md")

        slice_text = File.read(File.join(space_path, "artifacts", "01-first-slice.md"))
        assert_match(/^# Slice 01: first-slice/, slice_text)
        assert_match(/^## Rubric/, slice_text)
        assert_match(/^## Builder Prompt/, slice_text)

        yml = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        entry = yml.dig("architect", "slices").find { |s| s["name"] == "first-slice" }
        refute_nil entry
        assert_equal 1, entry["ordinal"]
        assert_equal "artifacts/01-first-slice.md", entry["file"]
        # `new` makes the freshly-created slice current.
        assert_equal "second-slice", yml.dig("architect", "current_slice")
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
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("architect", "init")
        invoke("architect", "new", "slice-1")
        slice_file = File.join(space_path, "artifacts", "01-slice-1.md")

        # First freeze — the scaffold already carries a "## Rubric" section.
        out, err = invoke("architect", "freeze", "slice-1")
        assert_empty err
        assert_match(/[0-9a-f]{7,40}/, out)

        yml = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        entry = yml.dig("architect", "slices").find { |s| s["name"] == "slice-1" }
        freeze_sha = entry["freeze_sha"]
        assert_match(/\A[0-9a-f]{40}\z/, freeze_sha)
        assert_equal "slice-1", yml.dig("architect", "current_slice")

        # Appending BELOW the freeze boundary (Builder Prompt) is allowed —
        # re-freeze returns the same sha, no error.
        File.write(slice_file, File.read(slice_file) + "\n### Lane A\nsome dispatched prompt\n")
        out2, err2 = invoke("architect", "freeze", "slice-1")
        assert_empty err2
        assert_match(/#{freeze_sha[0, 7]}/, out2)

        # Changing a FROZEN section (Rubric) is refused.
        text = File.read(slice_file)
        text = text.sub("## Rubric", "## Rubric\n\nGA9: tampered threshold")
        File.write(slice_file, text)
        _out3, err3 = invoke("architect", "freeze", "slice-1")
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
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))

      Dir.chdir(space_path) do
        invoke("architect", "init")
        invoke("architect", "new", "no-rubric")
        slice_file = File.join(space_path, "artifacts", "01-no-rubric.md")
        File.write(slice_file, "# Slice 01: no-rubric\n\n## Contract\n\njust a contract\n")

        _out, err = invoke("architect", "freeze", "no-rubric")
        assert_match(/no '## Rubric' section/, err)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_architect_block_survives_unrelated_space_command
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

        invoke("status", "done")

        yml_after = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        assert_equal "done", yml_after["status"], "status should be updated"
        assert_equal architect_before, yml_after["architect"], "architect: block must survive round-trip"
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
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("architect", "init")
        invoke("architect", "new", "s1")
        invoke("architect", "freeze", "s1")
        invoke("architect", "worktree", "add", "my-repo", "s1", "lane-a")

        wt_path = File.join(space_path, "tmp", "architect", "wt", "01-s1-lane-a")
        assert_path_exists wt_path

        File.write(File.join(wt_path, "builder_work.md"), "# builder commit\n")
        system("git", "-C", wt_path, "add", "builder_work.md")
        system("git", "-C", wt_path, "commit", "-q", "-m", "builder commit")

        out, err = invoke("architect", "verify", "s1")
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
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("architect", "init")
        invoke("architect", "new", "s1")
        invoke("architect", "freeze", "s1")
        invoke("architect", "worktree", "add", "my-repo", "s1", "lane-b")

        out, err = invoke("architect", "verify", "s1")
        assert_empty err
        rows = out.lines.select { |l| l.include?("scratch report") }
        assert rows.any? { |r| r.include?("FAIL") }, "expected (c) scratch report exists to be FAIL"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_verify_reports_pass_when_clean
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      invoke("init")
      space_path = create_real_space(File.join(env["HOME"]))
      create_real_repo(space_path, "my-repo")

      Dir.chdir(space_path) do
        invoke("architect", "init")
        invoke("architect", "new", "s1")
        invoke("architect", "freeze", "s1")
        invoke("architect", "worktree", "add", "my-repo", "s1", "lane-c")

        # The builder's scratch report (non-empty) lives in tmp/architect/.
        FileUtils.mkdir_p(File.join(space_path, "tmp", "architect"))
        File.write(File.join(space_path, "tmp", "architect", "01-s1-lane-c.report.md"),
          "# Lane Report\nSTATUS: COMPLETE\n")

        out, err = invoke("architect", "verify", "s1")
        assert_empty err
        refute_match(/FAIL/, out, "expected all checks to PASS, got:\n#{out}")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end
end
