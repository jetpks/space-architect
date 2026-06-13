# frozen_string_literal: true

require "test_helper"

class ShellTest < Minitest::Test
  include TestHelpers

  Shell = RepoTender::Shell

  # G4: Shell is non-blocking. A zero-exit run returns Success(stdout);
  # a non-zero exit returns Failure carrying argv + stderr + status;
  # two concurrent runs inside one Sync{} overlap (wall-clock < 0.6s).

  def test_success_returns_stdout
    in_async do
      result = Shell.run("echo", "hi")
      assert result.success?
      assert_equal "hi\n", result.success
    end
  end

  def test_success_with_chdir
    in_async do
      result = Shell.run("pwd", chdir: "/tmp")
      assert result.success?
      assert_includes result.success, "tmp"
    end
  end

  def test_nonzero_returns_failure_with_argv_stderr_status
    in_async do
      result = Shell.run("sh", "-c", "echo oops 1>&2; exit 3")
      assert result.failure?
      f = result.failure
      assert_equal ["sh", "-c", "echo oops 1>&2; exit 3"], f[:argv]
      assert_equal 3, f[:status]
      assert_equal "oops\n", f[:stderr]
    end
  end

  def test_env_is_passed_through
    in_async do
      result = Shell.run("sh", "-c", "echo $MYVAR", env: {MYVAR: "hello"})
      assert result.success?
      assert_equal "hello\n", result.success
    end
  end

  def test_concurrent_runs_overlap_in_one_sync
    in_async do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      barrier = Async::Barrier.new
      barrier.async { Shell.run("sh", "-c", "sleep 0.3") }
      barrier.async { Shell.run("sh", "-c", "sleep 0.3") }
      barrier.wait
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      # Sequential would be ≥0.6s; concurrent via the Fiber scheduler
      # finishes at ~0.3s. Assert < 0.6s with a comfortable margin.
      assert_operator elapsed, :<, 0.6, "expected concurrent runs to overlap, took #{elapsed.round(3)}s"
    end
  end

  def test_outside_async_raises
    error = assert_raises(RuntimeError) do
      Shell.run("echo", "hi")
    end
    assert_match(/Async::Task/, error.message)
  end
end
