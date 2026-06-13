# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "time"

class SyncEngineTest < Minitest::Test
  include TestHelpers

  Engine = RepoTender::Sync::Engine
  Plan = RepoTender::Sync::RepoPlan
  Config = RepoTender::Config::Config
  RepoRef = RepoTender::Config::RepoRef
  OrgRef = RepoTender::Config::OrgRef
  SCMGit = RepoTender::SCM::Git
  StateStore = RepoTender::State::Store
  Status = RepoTender::SCM::Status

  # ---- Test doubles (dependency injection on the engine's collaborators) ----

  # A pure-Ruby stub of SCM::Client. All methods return canned values
  # so the engine's plan logic can be exercised without real git.
  class StubSCM
    attr_reader :status_calls, :fetch_calls, :current_branch_calls,
      :default_branch_calls, :last_fetch_calls, :switch_calls,
      :clone_calls, :fast_forward_calls
    attr_accessor :status_value, :current_branch_value, :default_branch_value,
      :last_fetch_value, :next_status_value, :fetch_value,
      :switch_value, :clone_value, :fast_forward_value, :raise_on

    def initialize(status_value:, current_branch_value: "trunk",
      default_branch_value: "trunk", last_fetch_value: nil,
      next_status_value: nil, fetch_value: :ok,
      fail_paths: [], raise_on: nil)
      @status_value = status_value
      @current_branch_value = current_branch_value
      @default_branch_value = default_branch_value
      @last_fetch_value = last_fetch_value
      @next_status_value = next_status_value || status_value
      @fetch_value = fetch_value
      @switch_value = :ok
      @clone_value = :ok
      @fast_forward_value = :fast_forwarded
      @fail_paths = fail_paths.to_set
      @status_calls = 0
      @fetch_calls = 0
      @current_branch_calls = 0
      @default_branch_calls = 0
      @last_fetch_calls = 0
      @switch_calls = 0
      @clone_calls = 0
      @fast_forward_calls = 0
      @raise_on = raise_on
    end

    def status(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: status failed"}) if @fail_paths.include?(path)
      @status_calls += 1
      Dry::Monads::Success((@status_calls == 1) ? @status_value : @next_status_value)
    end

    def current_branch(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: current_branch failed"}) if @fail_paths.include?(path)
      @current_branch_calls += 1
      Dry::Monads::Success(@current_branch_value)
    end

    def default_branch(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: default_branch failed"}) if @fail_paths.include?(path)
      @default_branch_calls += 1
      Dry::Monads::Success(@default_branch_value)
    end

    def last_fetch_at(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: last_fetch_at failed"}) if @fail_paths.include?(path)
      @last_fetch_calls += 1
      Dry::Monads::Success(@last_fetch_value)
    end

    def fetch(path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: fetch failed"}) if @fail_paths.include?(path)
      @fetch_calls += 1
      Dry::Monads::Success(@fetch_value)
    end

    def switch(path, branch)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: switch failed"}) if @fail_paths.include?(path)
      @switch_calls += 1
      Dry::Monads::Success(@switch_value || branch)
    end

    def clone(url, path)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: clone failed"}) if @fail_paths.include?(path)
      @clone_calls += 1
      Dry::Monads::Success(@clone_value || path)
    end

    def fast_forward(path, default_branch)
      raise @raise_on if @raise_on
      return Dry::Monads::Failure({path: path, reason: "stub: fast_forward failed"}) if @fail_paths.include?(path)
      @fast_forward_calls += 1
      Dry::Monads::Success(@fast_forward_value)
    end
  end

  # A SlowSCM for the G7 concurrency test. Increments a shared
  # counter inside a Mutex when work starts, decrements when work
  # ends. The engine's Async::Semaphore(concurrency) is the only
  # thing that should bound the in-flight count.
  class SlowSCM < SCMGit
    def initialize(delay: 0.05)
      super()
      @delay = delay
      @counter = 0
      @max_seen = 0
      @lock = Mutex.new
    end

    attr_reader :max_seen, :counter

    def with_lock(&block)
      @lock.synchronize(&block)
    end

    def clone(url, path)
      probe { :ok }
      Dry::Monads::Success(path)
    end

    def fetch(_path)
      probe { :ok }
      Dry::Monads::Success(:ok)
    end

    def fast_forward(_path, _default)
      probe { :ok }
      Dry::Monads::Success(:fast_forwarded)
    end

    private

    def probe
      with_lock do
        @counter += 1
        @max_seen = [@max_seen, @counter].max
      end
      sleep(@delay)
      with_lock { @counter -= 1 }
      yield
    end
  end

  # A Forge stub for the G10 tests.
  class StubForge
    attr_reader :list_org_calls
    attr_accessor :response_for

    def initialize(response_for:)
      @response_for = response_for
      @list_org_calls = 0
    end

    def list_org(org_ref)
      @list_org_calls += 1
      @response_for.call(org_ref)
    end
  end

  # ---- Helpers ----

  def clean_status(branch: "trunk", upstream: "origin/trunk", ahead: 0, behind: 0)
    Status.new(clean: true, branch: branch, upstream: upstream, ahead: ahead, behind: behind)
  end

  def make_config(base_dir:, repos: [], orgs: [], refresh_interval: 3600, concurrency: 4)
    Config.new(
      base_dir: base_dir,
      refresh_interval: refresh_interval,
      concurrency: concurrency,
      repos: repos,
      orgs: orgs
    )
  end

  # Run the engine under a fresh XDG temp HOME so state.yaml lands
  # in a known location. Always creates a fresh temp base_dir (we
  # never want to write into the user's real ~/src/evergreen).
  # Yields (paths, base_dir, state_file).
  def with_engine_home
    Dir.mktmpdir("repo-tender-base-") do |base_dir|
      with_paths(base_dir: base_dir) do |env, paths|
        yield paths, base_dir, paths.state_file
      end
    end
  end

  # ===========================================================================
  # G1 — Clean + behind → fast-forward → status: clean
  # ===========================================================================
  def test_g1_clean_behind_fast_forwards_to_clean
    with_engine_home do |paths, base_dir, state_file|
      with_trunk_repo do |bare, clone|
        seed_initial_commit(clone)
        # Push a new commit from a second clone, then rewind the
        # original clone's trunk ref so it is one commit behind
        # origin/trunk.
        clone2 = File.join(File.dirname(clone), "clone2")
        system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone2,
          exception: true, out: File::NULL)
        Shell.run("git", "remote", "add", "origin", bare, chdir: clone2)
        Shell.run("git", "config", "user.email", "t@t.com", chdir: clone2)
        Shell.run("git", "config", "user.name", "T", chdir: clone2)
        Shell.run("git", "pull", "-q", "origin", "trunk", chdir: clone2)
        File.write(File.join(clone2, "remote.md"), "remote\n")
        Shell.run("git", "add", ".", chdir: clone2)
        Shell.run("git", "commit", "-qm", "remote commit", chdir: clone2)
        Shell.run("git", "push", "-q", "origin", "trunk", chdir: clone2)
        parent_sha = Shell.run("git", "rev-parse", "HEAD", chdir: clone).success.strip
        Shell.run("git", "update-ref", "refs/heads/trunk", parent_sha, chdir: clone)

        # Copy the clone into $BASE/github.com/ruby/ruby so the
        # engine can find it.
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        # State row exists with status: clean.
        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        refute_nil row
        assert_equal "clean", row.status

        # The new commit is on disk in the repo.
        assert File.exist?(File.join(repo_path, "remote.md")), "fast-forwarded commit missing"
      end
    end
  end

  # ===========================================================================
  # G2 — Fresh → skipped, no network
  # ===========================================================================
  def test_g2_fresh_repo_makes_no_network_call
    with_engine_home do |paths, base_dir, state_file|
      with_trunk_repo do |bare, clone|
        seed_initial_commit(clone)
        # Create a FETCH_HEAD with a recent mtime so the plan sees "fresh".
        Shell.run("git", "fetch", chdir: clone)
        # Place the repo under base_dir (preserving mtime so the
        # mtime_before / mtime_after comparison is meaningful).
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path, preserve: true)
        mtime_before = File.mtime(File.join(repo_path, ".git", "FETCH_HEAD"))

        config = make_config(base_dir: base_dir, repos: [ref], refresh_interval: 3600)
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"
        mtime_after = File.mtime(File.join(repo_path, ".git", "FETCH_HEAD"))
        assert_equal mtime_before, mtime_after,
          "FETCH_HEAD mtime changed on a fresh repo (engine performed a network call)"
      end
    end
  end

  # ===========================================================================
  # G3 — Dirty → byte-untouched + reported
  # ===========================================================================
  def test_g3_dirty_repo_left_byte_untouched_and_reported
    with_engine_home do |paths, base_dir, state_file|
      with_trunk_repo do |bare, clone|
        seed_initial_commit(clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # Capture the on-disk state before the run.
        File.read(File.join(repo_path, "README.md"))
        head_before = Shell.run("git", "rev-parse", "HEAD", chdir: repo_path).success.strip
        # Make it dirty: add a new file and a modification.
        File.write(File.join(repo_path, "README.md"), "modified-locally\n")
        File.write(File.join(repo_path, "local.txt"), "local\n")

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?

        # State row: status: dirty, no last_error.
        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "dirty", row.status
        assert_nil row.last_error

        # Working tree bytes are unchanged.
        assert_equal "modified-locally\n", File.read(File.join(repo_path, "README.md"))
        assert_equal "local\n", File.read(File.join(repo_path, "local.txt"))
        # HEAD is unchanged.
        head_after = Shell.run("git", "rev-parse", "HEAD", chdir: repo_path).success.strip
        assert_equal head_before, head_after, "HEAD changed on a dirty repo (no data loss)"
      end
    end
  end

  # ===========================================================================
  # G4 — Diverged → reported, no destruction
  # ===========================================================================
  def test_g4_diverged_repo_local_commits_intact
    with_engine_home do |paths, base_dir, state_file|
      with_trunk_repo do |bare, clone|
        seed_initial_commit(clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # Push a new commit from a second clone (so origin/trunk is
        # ahead of repo_path's local trunk).
        clone2 = File.join(File.dirname(clone), "clone2")
        system("git", "-c", "init.defaultBranch=trunk", "init", "-q", clone2,
          exception: true, out: File::NULL)
        Shell.run("git", "remote", "add", "origin", bare, chdir: clone2)
        Shell.run("git", "config", "user.email", "t@t.com", chdir: clone2)
        Shell.run("git", "config", "user.name", "T", chdir: clone2)
        Shell.run("git", "pull", "-q", "origin", "trunk", chdir: clone2)
        File.write(File.join(clone2, "remote.md"), "remote\n")
        Shell.run("git", "add", ".", chdir: clone2)
        Shell.run("git", "commit", "-qm", "remote commit", chdir: clone2)
        Shell.run("git", "push", "-q", "origin", "trunk", chdir: clone2)
        # NB: no explicit `git fetch` in repo_path — the plan's own
        # scm.fetch is what discovers the divergence. If we fetched
        # here, FETCH_HEAD would be "fresh" and the plan would skip
        # the rev-list probe (PRD §3.3 step 4 is before step 5).

        # Now make a local-only commit (ahead of origin).
        File.write(File.join(repo_path, "local.md"), "local\n")
        Shell.run("git", "add", ".", chdir: repo_path)
        Shell.run("git", "commit", "-qm", "local-only commit", chdir: repo_path)

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "diverged", row.status, "diverged repo should be reported"

        # The local commit is still in the log.
        log_out = Shell.run("git", "log", "--oneline", chdir: repo_path).success
        assert_includes log_out, "local-only commit"
        # The local file is still on disk.
        assert File.exist?(File.join(repo_path, "local.md"))
        # No reset --hard was performed.
        assert_equal "local\n", File.read(File.join(repo_path, "local.md"))
      end
    end
  end

  # ===========================================================================
  # G5 — Detached / wrong branch → switch only when clean
  # ===========================================================================
  def test_g5_wrong_branch_clean_switches_back_to_default
    with_engine_home do |paths, base_dir, state_file|
      with_trunk_repo do |bare, clone|
        seed_initial_commit(clone)
        Shell.run("git", "switch", "-c", "feature", chdir: clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "clean", row.status
        assert_equal "trunk", row.default_branch

        # The local branch is back on trunk.
        current = Shell.run("git", "symbolic-ref", "--short", "HEAD", chdir: repo_path).success.strip
        assert_equal "trunk", current
      end
    end
  end

  def test_g5_wrong_branch_dirty_left_untouched_and_reported
    with_engine_home do |paths, base_dir, state_file|
      with_trunk_repo do |bare, clone|
        seed_initial_commit(clone)
        Shell.run("git", "switch", "-c", "feature", chdir: clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        # Dirty the tree.
        File.write(File.join(repo_path, "dirty.txt"), "x")

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "wrong_branch", row.status, "dirty wrong-branch should be reported, not switched"
        assert_equal "trunk", row.default_branch

        # The local branch is still on feature (not switched).
        current = Shell.run("git", "symbolic-ref", "--short", "HEAD", chdir: repo_path).success.strip
        assert_equal "feature", current, "dirty wrong-branch was switched (engine guard failed)"
        # The dirty file is intact.
        assert_equal "x", File.read(File.join(repo_path, "dirty.txt"))
      end
    end
  end

  def test_g5_detached_dirty_left_untouched_and_reported
    with_engine_home do |paths, base_dir, state_file|
      with_trunk_repo do |bare, clone|
        seed_initial_commit(clone)
        head_sha = Shell.run("git", "rev-parse", "HEAD", chdir: clone).success.strip
        Shell.run("git", "checkout", "--detach", head_sha, chdir: clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        File.write(File.join(repo_path, "dirty.txt"), "x")

        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new.call(config: config, paths: paths)
        assert result.success?

        state = StateStore.load(state_file).success
        row = state.repos["github.com/ruby/ruby"]
        assert_equal "detached", row.status

        # Still detached.
        current = Shell.run("git", "symbolic-ref", "--short", "HEAD", chdir: repo_path)
        assert current.failure?, "detached HEAD should still be detached"
        # Dirty file intact.
        assert_equal "x", File.read(File.join(repo_path, "dirty.txt"))
      end
    end
  end

  # ===========================================================================
  # G6 — Missing path → clone to $BASE/host/owner/repo
  # ===========================================================================
  def test_g6_missing_path_clones_to_derived_path
    with_engine_home do |paths, base_dir, state_file|
      Dir.mktmpdir("repo-tender-bare-") do |bare_dir|
        bare = File.join(bare_dir, "bare.git")
        work = File.join(bare_dir, "work")
        system("git", "init", "-b", "trunk", "--bare", bare, exception: true, out: File::NULL)
        system("git", "-c", "init.defaultBranch=trunk", "init", "-q", work,
          exception: true, out: File::NULL)
        in_async do
          Shell.run("git", "remote", "add", "origin", bare, chdir: work)
          Shell.run("git", "config", "user.email", "t@t.com", chdir: work)
          Shell.run("git", "config", "user.name", "T", chdir: work)
          File.write(File.join(work, "README.md"), "hello\n")
          Shell.run("git", "add", ".", chdir: work)
          Shell.run("git", "commit", "-qm", "init", chdir: work)
          Shell.run("git", "push", "-q", "-u", "origin", "trunk", chdir: work)
        end

        ref = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
        expected_path = File.join(base_dir, "github.com", "foo", "bar")
        refute File.exist?(expected_path), "precondition: derived path should not exist"

        config = make_config(base_dir: base_dir, repos: [ref])
        url_builder = ->(_r) { "file://#{bare}" }
        result = Engine.new(url_builder: url_builder).call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        # The clone lands at exactly the derived path.
        assert File.directory?(expected_path), "clone did not land at #{expected_path}"
        assert File.directory?(File.join(expected_path, ".git")), "clone missing .git"

        # State row: status clean, default_branch trunk.
        state = StateStore.load(state_file).success
        row = state.repos["github.com/foo/bar"]
        refute_nil row
        assert_equal "clean", row.status
        assert_equal "trunk", row.default_branch
      end
    end
  end

  # ===========================================================================
  # G7 — Concurrency bound respected
  # ===========================================================================
  def test_g7_concurrency_two_bounds_in_flight_count
    Dir.mktmpdir("repo-tender-conc-") do |dir|
      base_dir = dir
      5.times do |i|
        FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "repo#{i}"))
      end
      with_paths(base_dir: base_dir) do |env, paths|
        refs = (0...5).map { |i| RepoRef.new(host: "github.com", owner: "owner", name: "repo#{i}") }
        config = make_config(base_dir: base_dir, repos: refs, concurrency: 2)
        slow = SlowSCM.new(delay: 0.05)
        result = Engine.new(scm: slow).call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"
        assert_operator slow.max_seen, :<=, 2,
          "max in-flight count was #{slow.max_seen}, expected <= 2 (semaphore bound failed)"
        # All 5 still completed.
        state = StateStore.load(paths.state_file).success
        assert_equal 5, state.repos.size
      end
    end
  end

  # ===========================================================================
  # G8 — Per-repo failure isolated + state written
  # ===========================================================================
  def test_g8_per_repo_failure_isolated_and_state_written
    Dir.mktmpdir("repo-tender-iso-") do |dir|
      base_dir = dir
      2.times do |i|
        FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "repo#{i}"))
      end
      with_paths(base_dir: base_dir) do |env, paths|
        refs = [
          RepoRef.new(host: "github.com", owner: "owner", name: "repo0"),
          RepoRef.new(host: "github.com", owner: "owner", name: "repo1")
        ]
        bad_path = File.join(base_dir, "github.com", "owner", "repo1")
        good_status = clean_status(branch: "trunk", ahead: 0, behind: 0)
        scm = StubSCM.new(
          status_value: good_status,
          current_branch_value: "trunk",
          default_branch_value: "trunk",
          last_fetch_value: nil,
          next_status_value: good_status,
          fail_paths: [bad_path]
        )
        config = make_config(base_dir: base_dir, repos: refs, concurrency: 2)
        result = Engine.new(scm: scm).call(config: config, paths: paths)
        assert result.success?, "engine should not abort on a per-repo failure: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        assert_equal 2, state.repos.size, "every processed repo should have a state row"

        good_row = state.repos["github.com/owner/repo0"]
        refute_nil good_row
        assert_equal "clean", good_row.status

        bad_row = state.repos["github.com/owner/repo1"]
        refute_nil bad_row
        assert_equal "error", bad_row.status
        refute_nil bad_row.last_error
        assert_includes bad_row.last_error, "stub"
      end
    end
  end

  # G8 supplementary: an unhandled raise from the SCM is captured by
  # the engine's last-resort rescue and the run completes.
  def test_g8_unhandled_exception_in_scm_is_captured
    Dir.mktmpdir("repo-tender-raise-") do |dir|
      base_dir = dir
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "owner", "boom"))
      with_paths(base_dir: base_dir) do |env, paths|
        ref = RepoRef.new(host: "github.com", owner: "owner", name: "boom")
        scm = StubSCM.new(
          status_value: clean_status,
          raise_on: "stub: forced raise"
        )
        config = make_config(base_dir: base_dir, repos: [ref])
        result = Engine.new(scm: scm).call(config: config, paths: paths)
        assert result.success?, "engine should not abort on an unhandled raise: #{result.failure.inspect}"
        state = StateStore.load(paths.state_file).success
        row = state.repos["github.com/owner/boom"]
        refute_nil row
        assert_equal "error", row.status
        assert_includes row.last_error, "unhandled"
        assert_includes row.last_error, "forced raise"
      end
    end
  end

  # ===========================================================================
  # G9 — Idempotent (2nd run no network)
  # ===========================================================================
  def test_g9_idempotent_second_run_no_network
    with_engine_home do |paths, base_dir, state_file|
      with_trunk_repo do |bare, clone|
        seed_initial_commit(clone)
        ref = RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")
        repo_path = File.join(base_dir, ref.host, ref.owner, ref.name)
        FileUtils.mkdir_p(File.dirname(repo_path))
        FileUtils.cp_r(clone, repo_path)

        config = make_config(base_dir: base_dir, repos: [ref], refresh_interval: 3600)

        # First run: performs a fetch.
        result1 = Engine.new.call(config: config, paths: paths)
        assert result1.success?
        mtime_after_run1 = File.mtime(File.join(repo_path, ".git", "FETCH_HEAD"))

        # Second run: no network (FETCH_HEAD mtime unchanged).
        sleep 0.01  # ensure mtime resolution can detect a touch
        result2 = Engine.new.call(config: config, paths: paths)
        assert result2.success?
        mtime_after_run2 = File.mtime(File.join(repo_path, ".git", "FETCH_HEAD"))
        assert_equal mtime_after_run1, mtime_after_run2,
          "second run modified FETCH_HEAD (network call was performed)"

        # Second-run statuses match first-run statuses.
        state1 = StateStore.load(state_file).success
        row1 = state1.repos["github.com/ruby/ruby"]
        state2 = StateStore.load(state_file).success
        row2 = state2.repos["github.com/ruby/ruby"]
        assert_equal row1.status, row2.status
      end
    end
  end

  # ===========================================================================
  # G10 — Org expansion + resilience
  # ===========================================================================
  def test_g10_org_expansion_discovers_repos_and_writes_state
    Dir.mktmpdir("repo-tender-org-") do |dir|
      base_dir = dir
      2.times do |i|
        FileUtils.mkdir_p(File.join(base_dir, "github.com", "socketry", "lib#{i}"))
      end
      with_paths(base_dir: base_dir) do |env, paths|
        discovered = [
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib0"),
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib1")
        ]
        forge = StubForge.new(response_for: ->(_org) { Dry::Monads::Success(discovered) })
        org = OrgRef.new(host: "github.com", name: "socketry")
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)

        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?, "engine failed: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        assert_equal 2, state.repos.size, "both org-discovered repos should have state rows"
        assert state.repos["github.com/socketry/lib0"]
        assert state.repos["github.com/socketry/lib1"]
        # Org is recorded with repo_count.
        org_row = state.orgs["github.com/socketry"]
        refute_nil org_row
        assert_equal 2, org_row.repo_count
      end
    end
  end

  def test_g10_org_list_failure_is_resilient
    Dir.mktmpdir("repo-tender-orgfail-") do |dir|
      base_dir = dir
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "explicit", "rep"))
      with_paths(base_dir: base_dir) do |env, paths|
        forge = StubForge.new(
          response_for: ->(org) { Dry::Monads::Failure({org: org.name, reason: "gh not authenticated"}) }
        )
        org = OrgRef.new(host: "github.com", name: "someorg")
        explicit = RepoRef.new(host: "github.com", owner: "explicit", name: "rep")
        config = make_config(base_dir: base_dir, repos: [explicit], orgs: [org], concurrency: 2)

        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?, "engine must not abort on an org-list failure: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        # Explicit repo is processed.
        assert state.repos["github.com/explicit/rep"], "explicit repo missing from state"
        # The org's discovered repos are absent.
        refute state.repos["github.com/someorg/whatever"], "discovered repos should not be in state"
        # The org is recorded with repo_count 0.
        org_row = state.orgs["github.com/someorg"]
        refute_nil org_row
        assert_equal 0, org_row.repo_count
      end
    end
  end

  def test_g10_explicit_repo_wins_dedupe_against_org_discovered
    Dir.mktmpdir("repo-tender-dedupe-") do |dir|
      base_dir = dir
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "shared", "rep"))
      with_paths(base_dir: base_dir) do |env, paths|
        explicit = RepoRef.new(host: "github.com", owner: "shared", name: "rep")
        discovered = [explicit]  # same identity
        forge = StubForge.new(response_for: ->(_o) { Dry::Monads::Success(discovered) })
        org = OrgRef.new(host: "github.com", name: "shared")
        config = make_config(base_dir: base_dir, repos: [explicit], orgs: [org], concurrency: 1)

        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?
        state = StateStore.load(paths.state_file).success
        # Only one row for the deduped repo.
        assert_equal 1, state.repos.size
        assert state.repos["github.com/shared/rep"]
        # Org recorded with repo_count 1 (the discovered count, not
        # the deduped count — this is the org's own discoverability,
        # not what the engine processed).
        assert_equal 1, state.orgs["github.com/shared"].repo_count
      end
    end
  end

  # ===========================================================================
  # G7 (CF3 part 2): an org-list Failure preserves prior good
  # `repo_count` + `last_listed_at` (NOT 0/nil) and sets `last_error`.
  # Previously-discovered repos remain present. The Slice 2 G10
  # behavior (run does not abort; failure recorded) stays intact.
  # ===========================================================================
  def test_g7_org_list_failure_preserves_prior_repo_count_and_records_error
    Dir.mktmpdir("repo-tender-cf3-") do |base_dir|
      # Two repos already discovered from a prior good run.
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "socketry", "lib0"))
      FileUtils.mkdir_p(File.join(base_dir, "github.com", "socketry", "lib1"))
      with_paths(base_dir: base_dir) do |env, paths|
        org = OrgRef.new(host: "github.com", name: "socketry")

        # Run 1: forge lists 2 repos successfully. State captures
        # repo_count: 2, last_listed_at: now, last_error: nil.
        discovered = [
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib0"),
          RepoRef.new(host: "github.com", owner: "socketry", name: "lib1")
        ]
        # Use a fixed clock for determinism.
        now1 = Time.utc(2026, 6, 13, 10, 0, 0)
        clock1 = -> { now1 }
        forge1 = StubForge.new(response_for: ->(_o) { Dry::Monads::Success(discovered) })
        scm1 = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        config1 = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)

        result1 = Engine.new(scm: scm1, forge: forge1, clock: clock1).call(config: config1, paths: paths)
        assert result1.success?, "run 1 should succeed: #{result1.failure.inspect}"

        state_after_run1 = StateStore.load(paths.state_file).success
        org_row1 = state_after_run1.orgs["github.com/socketry"]
        refute_nil org_row1
        assert_equal 2, org_row1.repo_count, "run 1 should set repo_count=2"
        # `Org#to_h_compact` serializes `last_listed_at` as an
        # ISO-8601 string (see state/store.rb); the next load
        # re-reads it as a String. The engine received a Time
        # (`now1`) and wrote that value through; the on-disk form
        # is the string.
        assert_equal now1.iso8601, org_row1.last_listed_at
        assert_nil org_row1.last_error
        # Both repos in state.
        assert state_after_run1.repos["github.com/socketry/lib0"]
        assert state_after_run1.repos["github.com/socketry/lib1"]

        # Run 2: same config, but the forge now fails. The
        # previously-discovered repos are NOT in `config.repos`
        # (only the orgs track them); the engine will look them
        # up via prev state via the `prev.repos.dup` semantics
        # in build_new_state, and they remain present even
        # though no new SCM probe happens (no org-discovered
        # repos to process in this run).
        now2 = Time.utc(2026, 6, 13, 11, 0, 0)
        clock2 = -> { now2 }
        forge2 = StubForge.new(
          response_for: ->(o) { Dry::Monads::Failure({org: o.name, reason: "gh not authenticated"}) }
        )
        scm2 = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0),
          next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        config2 = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)
        result2 = Engine.new(scm: scm2, forge: forge2, clock: clock2).call(config: config2, paths: paths)
        assert result2.success?, "run 2 should NOT abort on an org-list failure: #{result2.failure.inspect}"

        state_after_run2 = StateStore.load(paths.state_file).success
        org_row2 = state_after_run2.orgs["github.com/socketry"]
        refute_nil org_row2
        # CF3: prior good values are preserved, NOT clobbered to 0/nil.
        assert_equal 2, org_row2.repo_count, "CF3: repo_count must be preserved across transient failure"
        assert_equal now1.iso8601, org_row2.last_listed_at, "CF3: last_listed_at must be preserved across transient failure"
        # The failure is recorded (no longer nil).
        refute_nil org_row2.last_error
        assert_includes org_row2.last_error, "gh not authenticated"
        # Previously-discovered repos remain in state.
        assert state_after_run2.repos["github.com/socketry/lib0"], "lib0 vanished from state on transient failure"
        assert state_after_run2.repos["github.com/socketry/lib1"], "lib1 vanished from state on transient failure"
      end
    end
  end

  # Companion to G7: an org-list Failure on the FIRST run (no prior
  # state) records a last_error with repo_count: 0 and
  # last_listed_at: nil (no prior good to preserve).
  def test_g7_org_list_failure_on_first_run_records_error_with_zero_repo_count
    Dir.mktmpdir("repo-tender-cf3-first-") do |base_dir|
      with_paths(base_dir: base_dir) do |env, paths|
        org = OrgRef.new(host: "github.com", name: "socketry")
        forge = StubForge.new(
          response_for: ->(o) { Dry::Monads::Failure({org: o.name, reason: "rate limit"}) }
        )
        scm = StubSCM.new(
          status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
        )
        config = make_config(base_dir: base_dir, orgs: [org], concurrency: 2)

        result = Engine.new(scm: scm, forge: forge).call(config: config, paths: paths)
        assert result.success?, "first-run org-list failure should NOT abort: #{result.failure.inspect}"

        state = StateStore.load(paths.state_file).success
        org_row = state.orgs["github.com/socketry"]
        refute_nil org_row
        assert_equal 0, org_row.repo_count
        assert_nil org_row.last_listed_at
        refute_nil org_row.last_error
        assert_includes org_row.last_error, "rate limit"
      end
    end
  end
end
