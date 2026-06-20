# frozen_string_literal: true

require "test_helper"
require "stringio"

class LaunchdAgentTest < Minitest::Test
  include TestHelpers

  Agent = SpaceArchitect::Pristine::Launchd::Agent

  # Recording fake — captures every argv, returns canned output
  # per call. The "fail" response yields a Failure with the
  # same shape Shell.run uses.
  class RecordingRunner
    attr_reader :calls

    def initialize(responses: nil)
      @calls = []
      @responses = responses || []
    end

    # queue a response for the next call (in order)
    def queue(response)
      @responses << response
    end

    def run(*argv)
      @calls << argv
      r = @responses.shift
      if r.nil?
        # default: success with empty stdout
        Dry::Monads::Success("")
      elsif r.is_a?(Exception)
        raise r
      elsif r.is_a?(Hash) && r[:failure]
        Dry::Monads::Failure({argv: argv, stderr: r[:stderr] || "", status: r[:status] || 1})
      else
        Dry::Monads::Success(r.to_s)
      end
    end
  end

  def make_agent(runner, uid: 501, label: Agent::DEFAULT_LABEL)
    Agent.new(runner: runner, uid: uid, label: label)
  end

  # ---- G2: exact launchctl argv per operation ----

  def test_install_uses_bootstrap_gui_uid_with_plist
    runner = RecordingRunner.new
    agent = make_agent(runner, uid: 501)
    pp = "/tmp/foo/Library/LaunchAgents/com.example.x.plist"
    result = agent.install(pp)
    assert result.success?
    assert_equal [["launchctl", "bootstrap", "gui/501", pp]], runner.calls
  end

  def test_uninstall_uses_bootout_gui_uid_label
    runner = RecordingRunner.new
    agent = make_agent(runner, uid: 502, label: "com.example.x")
    result = agent.uninstall
    assert result.success?
    assert_equal [["launchctl", "bootout", "gui/502/com.example.x"]], runner.calls
  end

  def test_start_runs_bootstrap_then_enable
    runner = RecordingRunner.new
    agent = make_agent(runner, uid: 503, label: "com.example.y")
    pp = "/tmp/foo.plist"
    result = agent.start(pp)
    assert result.success?
    assert_equal [
      ["launchctl", "bootstrap", "gui/503", pp],
      ["launchctl", "enable", "gui/503/com.example.y"]
    ], runner.calls
  end

  def test_stop_runs_bootout_then_disable
    runner = RecordingRunner.new
    agent = make_agent(runner, uid: 504, label: "com.example.z")
    result = agent.stop
    assert result.success?
    assert_equal [
      ["launchctl", "bootout", "gui/504/com.example.z"],
      ["launchctl", "disable", "gui/504/com.example.z"]
    ], runner.calls
  end

  def test_restart_uses_kickstart_k
    runner = RecordingRunner.new
    agent = make_agent(runner, uid: 505, label: "com.example.q")
    result = agent.restart
    assert result.success?
    assert_equal [["launchctl", "kickstart", "-k", "gui/505/com.example.q"]], runner.calls
  end

  def test_nonzero_exit_surfaces_as_failure_not_raise
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "service not found", status: 3})
    agent = make_agent(runner, uid: 506, label: "com.example.r")
    result = agent.install("/tmp/r.plist")
    assert result.failure?
    failure = result.failure
    assert_equal 3, failure[:status]
    assert_match(/service not found/, failure[:stderr])
    # No raise — the runner was called exactly once.
    assert_equal 1, runner.calls.size
  end

  def test_start_short_circuits_on_bootstrap_failure
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "no plist", status: 1})
    agent = make_agent(runner, uid: 507, label: "com.example.s")
    result = agent.start("/tmp/s.plist")
    assert result.failure?
    # Only bootstrap ran — enable was NOT attempted.
    assert_equal [["launchctl", "bootstrap", "gui/507", "/tmp/s.plist"]], runner.calls
  end

  # ---- G4: status parses launchctl list output defensively ----

  def test_status_loaded_and_running
    runner = RecordingRunner.new
    output = "PID\tStatus\tLabel\n123\t0\tcom.example.loaded\n-\t0\tcom.example.other\n"
    runner.queue(output)
    agent = make_agent(runner, uid: 510, label: "com.example.loaded")
    result = agent.status
    assert result.success?
    s = result.success
    assert_equal true, s[:loaded]
    assert_equal true, s[:running]
    assert_equal 123, s[:pid]
    assert_equal 0, s[:last_exit]
  end

  def test_status_loaded_but_not_running
    runner = RecordingRunner.new
    output = "PID\tStatus\tLabel\n-\t-1\tcom.example.loaded\n"
    runner.queue(output)
    agent = make_agent(runner, uid: 511, label: "com.example.loaded")
    result = agent.status
    assert result.success?
    s = result.success
    assert_equal true, s[:loaded]
    assert_equal false, s[:running]
    assert_nil s[:pid]
    assert_equal(-1, s[:last_exit])
  end

  def test_status_not_loaded
    runner = RecordingRunner.new
    output = "PID\tStatus\tLabel\n-\t0\tcom.example.other\n"
    runner.queue(output)
    agent = make_agent(runner, uid: 512, label: "com.example.absent")
    result = agent.status
    assert result.success?
    s = result.success
    assert_equal false, s[:loaded]
    assert_equal false, s[:running]
  end

  def test_status_empty_output_does_not_raise
    runner = RecordingRunner.new
    runner.queue("")
    agent = make_agent(runner, uid: 513, label: "com.example.x")
    result = agent.status
    assert result.success?
    s = result.success
    assert_equal false, s[:loaded]
  end

  def test_status_garbage_output_does_not_raise
    runner = RecordingRunner.new
    runner.queue("not a plist output\nrandom garbage\n")
    agent = make_agent(runner, uid: 514, label: "com.example.x")
    result = agent.status
    assert result.success?
    s = result.success
    assert_equal false, s[:loaded]
  end

  def test_status_malformed_pid_does_not_raise
    runner = RecordingRunner.new
    runner.queue("notapid\t0\tcom.example.loaded\n")
    agent = make_agent(runner, uid: 515, label: "com.example.loaded")
    result = agent.status
    assert result.success?
    s = result.success
    assert_equal true, s[:loaded]
    assert_equal false, s[:running]
    assert_nil s[:pid]
  end

  # ---- Slice 5 / CF5: benign bootout → Success in stop/uninstall ----
  #
  # A `bootout` Failure with status 3 (POSIX ESRCH = "No such
  # process") or matching the not-loaded stderr markers is the
  # COMMON case at a 6h refresh interval — the agent is
  # already not loaded. We map it to Success idempotently. The
  # install/bootstrap path is UNAFFECTED (regression guard:
  # `test_nonzero_exit_surfaces_as_failure_not_raise` above).

  def test_stop_treats_status_3_bootout_as_benign_and_still_runs_disable
    runner = RecordingRunner.new
    # bootout returns the documented benign Failure; disable
    # returns Success (its real-world result on a not-loaded
    # service is "the flag is set" — it does not raise).
    runner.queue({failure: true, stderr: "Boot-out failed: 3: No such process", status: 3})
    agent = make_agent(runner, uid: 516, label: "com.example.benign")
    result = agent.stop
    assert result.success?, "expected Success for benign bootout, got #{result.inspect}"
    # G3 argv assertion: both bootout AND disable were invoked.
    assert_equal [
      ["launchctl", "bootout", "gui/516/com.example.benign"],
      ["launchctl", "disable", "gui/516/com.example.benign"]
    ], runner.calls
  end

  def test_stop_treats_stderr_no_such_process_as_benign_when_status_is_not_3
    # Defensive OR: a non-3 status whose stderr still says
    # "No such process" is also treated as benign (defends
    # against status drift).
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "No such process: service not loaded", status: 1})
    agent = make_agent(runner, uid: 517, label: "com.example.benign2")
    result = agent.stop
    assert result.success?
    assert_equal [
      ["launchctl", "bootout", "gui/517/com.example.benign2"],
      ["launchctl", "disable", "gui/517/com.example.benign2"]
    ], runner.calls
  end

  def test_stop_treats_could_not_find_specified_service_stderr_as_benign
    # The legacy "Could not find specified service" phrasing
    # is matched by the same defensive regex.
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "Could not find specified service", status: 1})
    agent = make_agent(runner, uid: 518, label: "com.example.legacy")
    result = agent.stop
    assert result.success?
    assert_equal 2, runner.calls.size
  end

  def test_stop_propagates_non_benign_bootout_failure_and_skips_disable
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "Operation not permitted", status: 1})
    agent = make_agent(runner, uid: 519, label: "com.example.real")
    result = agent.stop
    assert result.failure?
    failure = result.failure
    assert_equal 1, failure[:status]
    assert_match(/Operation not permitted/, failure[:stderr])
    # Disable was NOT attempted — non-benign bootout short-circuits.
    assert_equal [["launchctl", "bootout", "gui/519/com.example.real"]], runner.calls
  end

  def test_stop_propagates_disable_failure_after_benign_bootout
    # Benign bootout → we proceed to disable → disable fails
    # with a real error. The disable failure IS the final
    # result (we don't paper over real failures).
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "Boot-out failed: 3: No such process", status: 3})
    runner.queue({failure: true, stderr: "Operation not permitted", status: 1})
    agent = make_agent(runner, uid: 520, label: "com.example.disablefail")
    result = agent.stop
    assert result.failure?
    failure = result.failure
    assert_equal 1, failure[:status]
    assert_match(/Operation not permitted/, failure[:stderr])
    assert_equal 2, runner.calls.size
  end

  def test_uninstall_treats_status_3_bootout_as_benign
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "Boot-out failed: 3: No such process", status: 3})
    agent = make_agent(runner, uid: 521, label: "com.example.uninst")
    result = agent.uninstall
    assert result.success?
    assert_equal [["launchctl", "bootout", "gui/521/com.example.uninst"]], runner.calls
  end

  def test_uninstall_treats_stderr_no_such_process_as_benign
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "No such process", status: 7})
    agent = make_agent(runner, uid: 522, label: "com.example.uninst2")
    result = agent.uninstall
    assert result.success?
    assert_equal 1, runner.calls.size
  end

  def test_uninstall_propagates_non_benign_bootout_failure
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "Operation not permitted", status: 1})
    agent = make_agent(runner, uid: 523, label: "com.example.uninst3")
    result = agent.uninstall
    assert result.failure?
    failure = result.failure
    assert_equal 1, failure[:status]
    assert_match(/Operation not permitted/, failure[:stderr])
  end

  def test_install_bootstrap_status_3_still_fails_regression_guard
    # Regression guard: the benign mapping is bootout-only.
    # A bootstrap (install path) with status 3 must still
    # surface as Failure. Mirrors the Slice-4 manual-checklist
    # scenario where install can return status 3 for a
    # malformed plist.
    runner = RecordingRunner.new
    runner.queue({failure: true, stderr: "service not found", status: 3})
    agent = make_agent(runner, uid: 524, label: "com.example.installfail")
    result = agent.install("/tmp/install-fail.plist")
    assert result.failure?
    failure = result.failure
    assert_equal 3, failure[:status]
    assert_match(/service not found/, failure[:stderr])
  end
end
