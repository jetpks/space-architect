# frozen_string_literal: true

require "test_helper"
require "stringio"

class LaunchdAgentTest < Minitest::Test
  include TestHelpers

  Agent = RepoTender::Launchd::Agent

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
end
