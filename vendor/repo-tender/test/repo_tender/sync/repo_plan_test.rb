# frozen_string_literal: true

require "test_helper"
require "time"

class SyncRepoPlanTest < Minitest::Test
  include TestHelpers

  RepoPlan = SpaceArchitect::Pristine::Sync::RepoPlan
  Status = SpaceArchitect::Pristine::SCM::Status

  # A pure-Ruby stub of SCM::Client that records call counts and
  # returns canned values. This is dependency injection on the plan's
  # collaborator, not a mock of the class under test (RepoPlan).
  # Several tests also use a real SCM::Git against `with_trunk_repo`
  # to prove the plan's behavior is real-world, not just a pure
  # function of stubbed inputs.
  class StubSCM
    attr_reader :status_calls, :fetch_calls, :current_branch_calls,
      :default_branch_calls, :last_fetch_calls, :switch_calls,
      :clone_calls, :fast_forward_calls
    attr_accessor :status_value, :current_branch_value, :default_branch_value,
      :last_fetch_value, :fetch_value, :next_status_value,
      :switch_value, :clone_value, :fast_forward_value

    def initialize(status_value:, current_branch_value: "trunk",
      default_branch_value: "trunk", last_fetch_value: nil,
      next_status_value: nil, fetch_value: :ok)
      @status_value = status_value
      @current_branch_value = current_branch_value
      @default_branch_value = default_branch_value
      @last_fetch_value = last_fetch_value
      @next_status_value = next_status_value || status_value
      @fetch_value = fetch_value
      @switch_value = :ok
      @clone_value = :ok
      @fast_forward_value = :fast_forwarded
      @status_calls = 0
      @fetch_calls = 0
      @current_branch_calls = 0
      @default_branch_calls = 0
      @last_fetch_calls = 0
      @switch_calls = 0
      @clone_calls = 0
      @fast_forward_calls = 0
    end

    def status(_path)
      @status_calls += 1
      Dry::Monads::Success((@status_calls == 1) ? @status_value : @next_status_value)
    end

    def current_branch(_path)
      @current_branch_calls += 1
      Dry::Monads::Success(@current_branch_value)
    end

    def default_branch(_path)
      @default_branch_calls += 1
      Dry::Monads::Success(@default_branch_value)
    end

    def last_fetch_at(_path)
      @last_fetch_calls += 1
      Dry::Monads::Success(@last_fetch_value)
    end

    def fetch(_path)
      @fetch_calls += 1
      Dry::Monads::Success(@fetch_value)
    end

    def switch(_path, _branch)
      @switch_calls += 1
      Dry::Monads::Success(@switch_value)
    end

    def clone(_url, _path)
      @clone_calls += 1
      Dry::Monads::Success(@clone_value)
    end

    def fast_forward(_path, _default)
      @fast_forward_calls += 1
      Dry::Monads::Success(@fast_forward_value)
    end

    def sync_empty(_path)
      Dry::Monads::Success(:empty)
    end
  end

  def clean_status(branch: "trunk", upstream: "origin/trunk", ahead: 0, behind: 0)
    Status.new(clean: true, branch: branch, upstream: upstream, ahead: ahead, behind: behind)
  end

  def dirty_status(branch: "trunk", upstream: "origin/trunk")
    Status.new(clean: false, branch: branch, upstream: upstream, entries: ["1 .M N... 100644 100644 100644 ... README.md"])
  end

  def repo_ref(name = "ruby")
    SpaceArchitect::Pristine::Config::RepoRef.new(host: "github.com", owner: "ruby", name: name)
  end

  # ---- Decision-table unit tests against the stub SCM. ----

  def test_missing_path_returns_clone
    scm = StubSCM.new(status_value: clean_status)
    plan = RepoPlan.call(
      repo_ref: repo_ref,
      path: "/tmp/definitely-does-not-exist-#{rand(1_000_000)}",
      scm: scm, refresh_interval: 3600
    ).success
    assert_equal :clone, plan.action
    assert_equal "missing", plan.status
    assert_equal 0, scm.status_calls, "no SCM probe should run before the present? check"
  end

  def test_detached_clean_returns_switch
    scm = StubSCM.new(
      status_value: clean_status(branch: "(detached)"),
      current_branch_value: nil
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600
    ).success
    assert_equal :switch, plan.action
    assert_equal "detached", plan.status
  end

  def test_detached_dirty_returns_report_detached
    scm = StubSCM.new(
      status_value: dirty_status(branch: "(detached)"),
      current_branch_value: nil
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600
    ).success
    assert_equal :report_detached, plan.action
    assert_equal "detached", plan.status
  end

  def test_wrong_branch_clean_returns_switch
    scm = StubSCM.new(
      status_value: clean_status(branch: "feature"),
      current_branch_value: "feature",
      default_branch_value: "trunk"
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600
    ).success
    assert_equal :switch, plan.action
    assert_equal "wrong_branch", plan.status
  end

  def test_wrong_branch_dirty_returns_report_wrong_branch
    scm = StubSCM.new(
      status_value: dirty_status(branch: "feature"),
      current_branch_value: "feature",
      default_branch_value: "trunk"
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600
    ).success
    assert_equal :report_wrong_branch, plan.action
    assert_equal "wrong_branch", plan.status
  end

  def test_on_default_clean_dirty_returns_report_dirty
    scm = StubSCM.new(
      status_value: dirty_status(branch: "trunk"),
      current_branch_value: "trunk",
      default_branch_value: "trunk"
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600
    ).success
    assert_equal :report_dirty, plan.action
    assert_equal "dirty", plan.status
  end

  def test_on_default_clean_fresh_returns_skip_fresh_no_fetch
    fresh_time = Time.now - 30
    scm = StubSCM.new(
      status_value: clean_status(branch: "trunk"),
      current_branch_value: "trunk",
      default_branch_value: "trunk",
      last_fetch_value: fresh_time
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600,
      now: Time.now
    ).success
    assert_equal :skip_fresh, plan.action
    assert_equal "clean", plan.status
    assert_equal 0, scm.fetch_calls, "skip_fresh must not call scm.fetch (gate G2)"
  end

  def test_on_default_clean_stale_up_to_date_returns_up_to_date
    # No FETCH_HEAD (nil) → stale → fetch. After fetch, status shows
    # behind=0 ahead=0 → up_to_date.
    scm = StubSCM.new(
      status_value: clean_status(branch: "trunk"),
      current_branch_value: "trunk",
      default_branch_value: "trunk",
      last_fetch_value: nil,  # no FETCH_HEAD → stale
      next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 0)
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600,
      now: Time.now
    ).success
    assert_equal :up_to_date, plan.action
    assert_equal "clean", plan.status
    assert_equal 1, scm.fetch_calls
  end

  def test_on_default_clean_stale_behind_returns_fast_forward
    scm = StubSCM.new(
      status_value: clean_status(branch: "trunk"),
      current_branch_value: "trunk",
      default_branch_value: "trunk",
      last_fetch_value: nil,
      next_status_value: clean_status(branch: "trunk", ahead: 0, behind: 3)
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600,
      now: Time.now
    ).success
    assert_equal :fast_forward, plan.action
    assert_equal "clean", plan.status
    assert_equal 1, scm.fetch_calls
  end

  def test_on_default_clean_stale_diverged_returns_report_diverged
    scm = StubSCM.new(
      status_value: clean_status(branch: "trunk"),
      current_branch_value: "trunk",
      default_branch_value: "trunk",
      last_fetch_value: nil,
      next_status_value: clean_status(branch: "trunk", ahead: 2, behind: 1)
    )
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600,
      now: Time.now
    ).success
    assert_equal :report_diverged, plan.action
    assert_equal "diverged", plan.status
  end

  def test_probe_failure_translates_to_report_error
    # status returns Failure → :report_error
    failing_scm = Class.new do
      def status(_path) = Dry::Monads::Failure({reason: "boom"})
      def current_branch(_path) = Dry::Monads::Success("trunk")
      def default_branch(_path) = Dry::Monads::Success("trunk")
      def last_fetch_at(_path) = Dry::Monads::Success(nil)
    end.new
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: failing_scm, refresh_interval: 3600
    ).success
    assert_equal :report_error, plan.action
    assert_equal "error", plan.status
  end

  # ---- Real-SCM smoke tests (the plan against a real temp repo). ----

  def test_real_repo_on_trunk_up_to_date_after_seed
    with_trunk_repo do |_bare, clone|
      seed_initial_commit(clone)
      scm = SpaceArchitect::Pristine::SCM::Git.new
      plan = RepoPlan.call(
        repo_ref: repo_ref, path: clone, scm: scm, refresh_interval: 3600,
        now: Time.now
      ).success
      # After seed, the clone is at the same commit as origin/trunk.
      # No FETCH_HEAD exists from `git push`, so the plan fetches,
      # discovers behind=0, and returns :up_to_date (or :skip_fresh
      # if a prior test left a recent FETCH_HEAD — we run in a
      # fresh tempdir so this is :up_to_date).
      assert_includes [:up_to_date, :skip_fresh], plan.action,
        "expected :up_to_date or :skip_fresh, got #{plan.action.inspect}"
      assert_equal "clean", plan.status
    end
  end

  def test_real_repo_dirty_returns_report_dirty
    with_trunk_repo do |_bare, clone|
      seed_initial_commit(clone)
      File.write(File.join(clone, "README.md"), "modified\n")
      scm = SpaceArchitect::Pristine::SCM::Git.new
      plan = RepoPlan.call(
        repo_ref: repo_ref, path: clone, scm: scm, refresh_interval: 3600,
        now: Time.now
      ).success
      assert_equal :report_dirty, plan.action
      assert_equal "dirty", plan.status
    end
  end

  def test_real_repo_wrong_branch_dirty_returns_report_wrong_branch
    with_trunk_repo do |_bare, clone|
      seed_initial_commit(clone)
      Shell.run("git", "switch", "-c", "feature", chdir: clone)
      File.write(File.join(clone, "dirty.txt"), "x")
      scm = SpaceArchitect::Pristine::SCM::Git.new
      plan = RepoPlan.call(
        repo_ref: repo_ref, path: clone, scm: scm, refresh_interval: 3600,
        now: Time.now
      ).success
      assert_equal :report_wrong_branch, plan.action
      assert_equal "wrong_branch", plan.status
    end
  end

  def test_real_repo_wrong_branch_clean_returns_switch
    with_trunk_repo do |_bare, clone|
      seed_initial_commit(clone)
      Shell.run("git", "switch", "-c", "feature", chdir: clone)
      scm = SpaceArchitect::Pristine::SCM::Git.new
      plan = RepoPlan.call(
        repo_ref: repo_ref, path: clone, scm: scm, refresh_interval: 3600,
        now: Time.now
      ).success
      assert_equal :switch, plan.action
      assert_equal "wrong_branch", plan.status
    end
  end

  # ---- GB2 (stub): unborn clean → :sync_empty ----

  def test_unborn_clean_returns_sync_empty
    unborn_clean = Status.new(clean: true, branch: "trunk", unborn: true)
    scm = StubSCM.new(status_value: unborn_clean)
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600
    ).success
    assert_equal :sync_empty, plan.action
    assert_equal "clean", plan.status
    assert_equal 0, scm.current_branch_calls,
      "unborn path must not call current_branch (default_branch would fail on empty remote)"
    assert_equal 0, scm.default_branch_calls,
      "unborn path must not call default_branch (exits non-zero on empty remote)"
  end

  # ---- GB4 (stub): unborn dirty → :report_dirty, no mutation ----

  def test_unborn_dirty_returns_report_dirty
    unborn_dirty = Status.new(clean: false, branch: "trunk", unborn: true,
      entries: ["? local.txt"])
    scm = StubSCM.new(status_value: unborn_dirty)
    plan = RepoPlan.call(
      repo_ref: repo_ref, path: "/tmp", scm: scm, refresh_interval: 3600
    ).success
    assert_equal :report_dirty, plan.action
    assert_equal "dirty", plan.status
    assert_equal 0, scm.current_branch_calls, "unborn dirty path must not call current_branch"
    assert_equal 0, scm.default_branch_calls, "unborn dirty path must not call default_branch"
    assert_equal 0, scm.fetch_calls, "unborn dirty path must not fetch"
  end

  # ---- GB2 (real git): unborn clean → :sync_empty ----

  def test_real_empty_repo_returns_sync_empty
    with_empty_repo do |_bare, clone|
      scm = SpaceArchitect::Pristine::SCM::Git.new
      plan = RepoPlan.call(
        repo_ref: repo_ref, path: clone, scm: scm, refresh_interval: 3600,
        now: Time.now
      ).success
      assert_equal :sync_empty, plan.action, "empty repo should plan :sync_empty, not :report_error"
      assert_equal "clean", plan.status
    end
  end

  # ---- GB4 (real git): unborn dirty → :report_dirty ----

  def test_real_empty_repo_with_untracked_file_returns_report_dirty
    with_empty_repo do |_bare, clone|
      File.write(File.join(clone, "local.txt"), "do not touch me\n")
      scm = SpaceArchitect::Pristine::SCM::Git.new
      plan = RepoPlan.call(
        repo_ref: repo_ref, path: clone, scm: scm, refresh_interval: 3600,
        now: Time.now
      ).success
      assert_equal :report_dirty, plan.action, "unborn dirty should plan :report_dirty"
      assert_equal "dirty", plan.status
    end
  end
end
