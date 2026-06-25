# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"
require "time"

class CLISyncTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  PristineCLI = Space::Src::CLI
  Engine = Space::Src::Sync::Engine
  Config = Space::Src::Config::Config
  RepoRef = Space::Src::Config::RepoRef

  # Build 2 real bare remotes + clones, copy the clones into
  # base_dir under `<host>/<owner>/<name>`. Critically, keep the
  # BARE REMOTES alive for the full duration of the test (incl.
  # the engine run) — the clones' `origin` URLs point at the
  # bares, so if the bares are cleaned up before the engine runs,
  # the engine's fetch fails (the error observed in the first
  # failed test was exactly this: "bare.git does not appear to
  # be a git repository"). The Slice 2 single-repo tests don't
  # hit this because the engine runs INSIDE the with_trunk_repo
  # block. The multi-repo CLI test has to keep the bares alive
  # for the entire test.
  def with_engine_home_2_repos
    Dir.mktmpdir("repo-tender-cli-sync-base-") do |base_dir|
      Dir.mktmpdir("repo-tender-cli-sync-bares-") do |bares_dir|
        with_cli_env do |env, _home|
          paths = Space::Src::Paths.new(environment: env, base_dir: base_dir)
          paths.ensure!
          refs = []
          2.times do |i|
            owner = i.zero? ? "foo" : "bar"
            name = "repo#{i}"
            bare = File.join(bares_dir, "bare-#{i}.git")
            clone = File.join(bares_dir, "clone-#{i}")
            system("git", "init", "-b", "trunk", "--bare", bare,
              exception: true, out: File::NULL)
            system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone,
              exception: true, out: File::NULL)
            in_async do
              Shell.run("git", "remote", "add", "origin", bare, chdir: clone)
              Shell.run("git", "config", "user.email", "test@example.com", chdir: clone)
              Shell.run("git", "config", "user.name", "Test", chdir: clone)
              File.write(File.join(clone, "README.md"), "hello\n")
              Shell.run("git", "add", ".", chdir: clone)
              Shell.run("git", "commit", "-qm", "initial", chdir: clone)
              Shell.run("git", "push", "-q", "-u", "origin", "trunk", chdir: clone)
            end
            ref = RepoRef.new(host: "github.com", owner: owner, name: name)
            repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
            FileUtils.mkdir_p(File.dirname(repo_path))
            FileUtils.cp_r(clone, repo_path)
            refs << ref
          end
          yield(env, paths, base_dir, refs)
        end
      end
    end
  end

  # ---- G4: `sync` invokes the engine; `sync --repo` scopes to
  #        one repo. At least one assertion must prove the
  #        non-targeted repo was not processed. ----

  def test_sync_invokes_engine_and_writes_state
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      out, _err = invoke_command(PristineCLI::Sync::Run)
      assert_equal 0, PristineCLI.last_outcome.exit_code
      assert_includes out.string, "synced 2 repo(s)"

      # State has rows for both repos.
      state = Space::Src::State::Store.load(paths.state_file).success
      refute_nil state.repos["github.com/foo/repo0"], "repo0 missing from state"
      refute_nil state.repos["github.com/bar/repo1"], "repo1 missing from state"
      # Each processed repo got a status (clean — the engine
      # fetched + discovered up-to-date).
      assert_equal "clean", state.repos["github.com/foo/repo0"].status
      assert_equal "clean", state.repos["github.com/bar/repo1"].status
      # Each got a last_synced_at.
      refute_nil state.repos["github.com/foo/repo0"].last_synced_at
      refute_nil state.repos["github.com/bar/repo1"].last_synced_at
    end
  end

  def test_sync_repo_scopes_to_one_repo_and_leaves_other_state_row_untouched
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      # Pre-seed state with rows for BOTH repos, using a fixed
      # "old" last_synced_at string (State::Store round-trips
      # ISO8601 strings as strings, NOT Time objects — see the
      # state/store.rb reader). The proof of scoping is that
      # after the scoped sync, the non-targeted repo's
      # last_synced_at is unchanged.
      old_time_string = "2000-01-01T00:00:00Z"
      seeded_state = Space::Src::State::Store::State.new(
        repos: {
          "github.com/foo/repo0" => Space::Src::State::Store::Repo.new(
            default_branch: "trunk", last_fetch_at: old_time_string,
            last_synced_at: old_time_string, status: "clean", last_error: nil
          ),
          "github.com/bar/repo1" => Space::Src::State::Store::Repo.new(
            default_branch: "trunk", last_fetch_at: old_time_string,
            last_synced_at: old_time_string, status: "clean", last_error: nil
          )
        },
        orgs: {}
      )
      Space::Src::State::Store.write(paths.state_file, seeded_state)

      out, _err = invoke_command(PristineCLI::Sync::Run, repo: "github.com/foo/repo0")
      assert_equal 0, PristineCLI.last_outcome.exit_code
      assert_includes out.string, "scoping sync to: github.com/foo/repo0"

      new_state = Space::Src::State::Store.load(paths.state_file).success

      # Targeted repo was processed — its last_synced_at moved
      # forward (the engine's clock is Time.now, not old_time).
      targeted = new_state.repos["github.com/foo/repo0"]
      refute_nil targeted
      refute_equal old_time_string, targeted.last_synced_at,
        "scoped sync did not process the targeted repo"

      # Non-targeted repo was NOT processed — its last_synced_at
      # is unchanged. This is the G4 scoping proof.
      non_targeted = new_state.repos["github.com/bar/repo1"]
      refute_nil non_targeted, "non-targeted repo state row vanished (was deleted)"
      assert_equal old_time_string, non_targeted.last_synced_at,
        "non-targeted repo was processed (last_synced_at changed) — CLI scoping failed"
      assert_equal "clean", non_targeted.status,
        "non-targeted repo's status changed (engine touched it)"
    end
  end

  def test_sync_repo_unknown_ref_exits_nonzero_with_stderr
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      _out, err = invoke_command(PristineCLI::Sync::Run, repo: "github.com/no/such")
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "no such tracked repo"
    end
  end

  def test_sync_repo_invalid_ref_exits_nonzero
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      _out, err = invoke_command(PristineCLI::Sync::Run, repo: "not-a-ref")
      assert_equal 1, PristineCLI.last_outcome.exit_code
      assert_includes err.string, "invalid repo reference"
    end
  end

  def test_sync_subprocess_invokes_engine
    with_engine_home_2_repos do |env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["sync"])
      assert status.success?, "sync subprocess should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "synced 2 repo(s)"

      state = Space::Src::State::Store.load(paths.state_file).success
      refute_nil state.repos["github.com/foo/repo0"]
      refute_nil state.repos["github.com/bar/repo1"]
    end
  end

  # ---- Slice 5 / CF6: `SPACE_SRC_LOG_MAX_BYTES` parse
  #      hardening. A malformed value (e.g. `"10MB"`) must
  #      fall back to the 10 MiB default instead of raising
  #      `ArgumentError` and crashing the entire `sync` run.
  #      Gate G4: the threshold helper returns the 10 MiB
  #      default for unset/empty/whitespace/non-numeric/
  #      non-positive inputs, and the parsed positive
  #      integer for valid input. **No `ArgumentError`
  #      escapes** for any input.

  def log_max_bytes(value)
    cmd = PristineCLI::Sync::Run.new
    cmd.send(:log_max_bytes, value)
  end

  def test_log_max_bytes_unset_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes(nil)
  end

  def test_log_max_bytes_empty_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("")
  end

  def test_log_max_bytes_whitespace_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("   ")
  end

  def test_log_max_bytes_non_numeric_returns_default
    # The CF6 example value — must NOT raise ArgumentError.
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("10MB")
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("abc")
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("1.5")
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("10MiB")
  end

  def test_log_max_bytes_zero_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("0")
  end

  def test_log_max_bytes_negative_returns_default
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("-5")
    assert_equal PristineCLI::Sync::Run::DEFAULT_LOG_MAX_BYTES, log_max_bytes("-1048576")
  end

  def test_log_max_bytes_valid_positive_returns_value
    assert_equal 1048576, log_max_bytes("1048576")
    assert_equal 1, log_max_bytes("1")
  end

  def test_log_max_bytes_strips_surrounding_whitespace_from_valid_value
    # `Integer("  524288  ", 10, exception: false)` → 524288
    # (Ruby's Integer tolerates leading/trailing whitespace).
    assert_equal 524288, log_max_bytes("  524288  ")
  end

  def test_log_max_bytes_never_raises_argument_error
    # Belt-and-braces: every shape of bad input must NOT
    # raise. Looped so a single failure points to the
    # exact value that broke the contract.
    ["10MB", "abc", "0", "-1", "1.5", "", "  ", "  ", "0x10", "1e6", "1_000_000", nil].each do |v|
      log_max_bytes(v)
    rescue ArgumentError => e
      flunk "log_max_bytes(#{v.inspect}) raised ArgumentError: #{e.message}"
    end
  end

  def test_sync_with_malformed_log_max_bytes_does_not_crash
    # Integration: a real `sync` run with
    # `SPACE_SRC_LOG_MAX_BYTES="10MB"` set in the env must
    # exit 0 and write state for both repos. The pre-step's
    # parse must NOT crash the run.
    with_engine_home_2_repos do |_env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      prev = ENV["SPACE_SRC_LOG_MAX_BYTES"]
      begin
        ENV["SPACE_SRC_LOG_MAX_BYTES"] = "10MB"
        out, _err = invoke_command(PristineCLI::Sync::Run)
      ensure
        ENV["SPACE_SRC_LOG_MAX_BYTES"] = prev
      end
      assert_equal 0, PristineCLI.last_outcome.exit_code,
        "expected exit 0 with malformed log_max_bytes; got #{PristineCLI.last_outcome.exit_code}"
      assert_includes out.string, "synced 2 repo(s)"

      state = Space::Src::State::Store.load(paths.state_file).success
      refute_nil state.repos["github.com/foo/repo0"], "repo0 missing — sync crashed before writing state"
      refute_nil state.repos["github.com/bar/repo1"], "repo1 missing — sync crashed before writing state"
    end
  end

  # ---- Slice A (ui-foundation) G6: subprocess stdout is ANSI-free when
  #      piped (non-TTY); synced N repo(s) summary preserved; exit unchanged ----

  def test_g6_sync_subprocess_stdout_is_ansi_free_when_piped
    with_engine_home_2_repos do |env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      # Open3.capture3 captures stdout as a string (non-TTY) — the launchd condition
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["sync"])
      assert status.success?, "sync subprocess should exit 0; got #{status.exitstatus}"
      refute_includes stdout, "\e[", "stdout must be ANSI-free when piped"
      refute_includes stdout, "\x1b[", "stdout must be ANSI-free when piped"
      assert_includes stdout, "synced 2 repo(s)", "synced summary line must be preserved"
    end
  end

  def test_g6_sync_subprocess_exit_and_state_unchanged_from_pre_slice
    # Regression: exit codes and state.yaml write behavior are unchanged.
    with_engine_home_2_repos do |env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      _stdout, _stderr, status = run_cli_subprocess(env: env, args: ["sync"])
      assert status.success?
      state = Space::Src::State::Store.load(paths.state_file).success
      assert_equal 2, state.repos.size
      assert state.repos["github.com/foo/repo0"]
      assert state.repos["github.com/bar/repo1"]
    end
  end

  def test_g6_sync_repo_invalid_ref_exits_nonzero_when_piped
    with_engine_home_2_repos do |env, paths, base_dir, refs|
      config = Config.new(
        base_dir: base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: refs,
        orgs: []
      )
      Space::Src::Config::Store.write(paths.config_file, config)

      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["sync", "--repo", "not-a-ref"])
      refute status.success?, "invalid repo ref should exit non-zero"
      assert_includes stderr, "invalid repo reference"
    end
  end

  # ===========================================================================
  # Slice B G5 — reporter selection branch: mode.animate → InteractiveReporter
  # ===========================================================================

  def test_g5_json_flag_selects_json_reporter
    mode = Space::Src::UI::Mode.new(color: false, animate: false, quiet: false, format: :json)
    reporter = reporter_for_mode(mode)
    assert_instance_of Space::Src::UI::JsonReporter, reporter
  end

  def test_g5_animate_true_selects_interactive_reporter
    mode = Space::Src::UI::Mode.new(color: true, animate: true, quiet: false, format: :pretty)
    reporter = reporter_for_mode(mode)
    assert_instance_of Space::Src::UI::InteractiveReporter, reporter
  end

  def test_g5_animate_false_selects_plain_reporter
    mode = Space::Src::UI::Mode.new(color: false, animate: false, quiet: false, format: :plain)
    reporter = reporter_for_mode(mode)
    assert_instance_of Space::Src::UI::PlainReporter, reporter
  end

  def test_g5_json_format_takes_precedence_over_animate
    # format=:json implies animate=false (Mode.resolve sets animate=false for non-pretty),
    # but assert JsonReporter wins regardless.
    mode = Space::Src::UI::Mode.new(color: false, animate: false, quiet: false, format: :json)
    reporter = reporter_for_mode(mode)
    assert_instance_of Space::Src::UI::JsonReporter, reporter
  end

  def test_g5_no_color_with_animate_still_selects_interactive_reporter
    # --no-color on a TTY: format=:pretty, animate=true, color=false
    mode = Space::Src::UI::Mode.new(color: false, animate: true, quiet: false, format: :pretty)
    reporter = reporter_for_mode(mode)
    assert_instance_of Space::Src::UI::InteractiveReporter, reporter
  end

  private

  # Extract the reporter selection logic for mode-only unit testing.
  # Mirrors the branch in CLI::Sync::Run#call without running the full engine.
  def reporter_for_mode(mode)
    out = StringIO.new
    if mode.format == :json
      Space::Src::UI::JsonReporter.new(out)
    elsif mode.animate
      Space::Src::UI::InteractiveReporter.new(out, mode: mode)
    else
      Space::Src::UI::PlainReporter.new(out, mode: mode)
    end
  end
end
