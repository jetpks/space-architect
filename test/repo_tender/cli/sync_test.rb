# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"
require "time"

class CLISyncTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  RepoTenderCLI = RepoTender::CLI
  Engine = RepoTender::Sync::Engine
  Config = RepoTender::Config::Config
  RepoRef = RepoTender::Config::RepoRef

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
          paths = RepoTender::Paths.new(environment: env, base_dir: base_dir)
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
      RepoTender::Config::Store.write(paths.config_file, config)

      out, _err = invoke_command(RepoTenderCLI::Sync::Run)
      assert_equal 0, RepoTenderCLI.last_outcome.exit_code
      assert_includes out.string, "synced 2 repo(s)"

      # State has rows for both repos.
      state = RepoTender::State::Store.load(paths.state_file).success
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
      RepoTender::Config::Store.write(paths.config_file, config)

      # Pre-seed state with rows for BOTH repos, using a fixed
      # "old" last_synced_at string (State::Store round-trips
      # ISO8601 strings as strings, NOT Time objects — see the
      # state/store.rb reader). The proof of scoping is that
      # after the scoped sync, the non-targeted repo's
      # last_synced_at is unchanged.
      old_time_string = "2000-01-01T00:00:00Z"
      seeded_state = RepoTender::State::Store::State.new(
        repos: {
          "github.com/foo/repo0" => RepoTender::State::Store::Repo.new(
            default_branch: "trunk", last_fetch_at: old_time_string,
            last_synced_at: old_time_string, status: "clean", last_error: nil
          ),
          "github.com/bar/repo1" => RepoTender::State::Store::Repo.new(
            default_branch: "trunk", last_fetch_at: old_time_string,
            last_synced_at: old_time_string, status: "clean", last_error: nil
          )
        },
        orgs: {}
      )
      RepoTender::State::Store.write(paths.state_file, seeded_state)

      out, _err = invoke_command(RepoTenderCLI::Sync::Run, repo: "github.com/foo/repo0")
      assert_equal 0, RepoTenderCLI.last_outcome.exit_code
      assert_includes out.string, "scoping sync to: github.com/foo/repo0"

      new_state = RepoTender::State::Store.load(paths.state_file).success

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
      RepoTender::Config::Store.write(paths.config_file, config)

      _out, err = invoke_command(RepoTenderCLI::Sync::Run, repo: "github.com/no/such")
      assert_equal 1, RepoTenderCLI.last_outcome.exit_code
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
      RepoTender::Config::Store.write(paths.config_file, config)

      _out, err = invoke_command(RepoTenderCLI::Sync::Run, repo: "not-a-ref")
      assert_equal 1, RepoTenderCLI.last_outcome.exit_code
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
      RepoTender::Config::Store.write(paths.config_file, config)

      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["sync"])
      assert status.success?, "sync subprocess should exit 0; got #{status.exitstatus}"
      assert_includes stdout, "synced 2 repo(s)"

      state = RepoTender::State::Store.load(paths.state_file).success
      refute_nil state.repos["github.com/foo/repo0"]
      refute_nil state.repos["github.com/bar/repo1"]
    end
  end
end
