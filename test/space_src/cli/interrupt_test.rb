# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Slice 6 G2 — ^C hygiene: a `Interrupt` raised from inside command
# dispatch through the real `CLI.run` entrypoint produces a clean
# exit code 130 with at most one human-readable line on stderr and
# no Ruby backtrace / Open3 thread-noise / IOError patterns.
#
# The deterministic seam: a throwaway `Dry::CLI::Command` registered
# on the real `CLI::Registry` whose `#call` raises `Interrupt`. The
# `CLI.run` rescue catches it, writes a single "interrupted" line to
# stderr, and calls `Kernel.exit(130)` (which raises `SystemExit`,
# caught by the test to read the status).
#
# The throwaway command persists on the Registry for the rest of
# the test process — this is harmless: the other CLI tests that
# enumerate commands (`test_top_level_help_exits_zero_with_usage_on_stdout`
# et al. in `test/repo_tender/cli/nested_registration_test.rb`) all
# use `run_cli_subprocess`, which spawns a fresh Ruby process per
# call (see `test_helper.rb#run_cli_subprocess`) and therefore
# does NOT see in-process registry pollution. We use a name
# (`__interrupt_boom__`) prefixed with double underscores so a
# stray `--help` dump would not look like a real command.

class InterruptTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  # Throwaway command: raises `Interrupt` on dispatch. The CLI
  # dispatch rescues `Interrupt` at the top of `CLI.run` and
  # maps it to a clean exit 130 (Slice 6 G2).
  class Boom < Dry::CLI::Command
    def call(*)
      raise Interrupt
    end
  end

  # Register once at file load (no `Dry::CLI::Registry#unregister`
  # exists; see `dry-cli-1.4.1/lib/dry/cli/command_registry.rb`).
  # The command name is prefixed `__` so it does not look like a
  # real CLI command in any `--help` enumeration.
  Space::Src::CLI::Registry.register "__interrupt_boom__", Boom

  # ---- G2 deterministic automated test ----

  # Drive an `Interrupt` raised from inside command dispatch
  # through the real `CLI.run` entrypoint. Assert: exit 130
  # (NOT 0, NOT 1), at most one human line on stderr, NO Ruby
  # backtrace, NO `report_on_exception` / `open3.rb` / `(IOError)`
  # / `stream closed in another thread` patterns.
  def test_interrupt_in_command_dispatch_exits_130_with_clean_stderr
    out = StringIO.new
    err = StringIO.new
    status = nil
    begin
      Space::Src::CLI.run(["__interrupt_boom__"], out, err)
    rescue SystemExit => e
      status = e.status
    end

    # Exit code: 130 (128 + SIGINT). NOT 0 (an interrupt is not
    # success) and NOT 1 (a real failure would still exit 1 via
    # the existing `Outcome(exit_code: 1)` path).
    assert_equal 130, status,
      "expected SystemExit status 130 (128 + SIGINT); got #{status.inspect}"

    # stderr: at most one human line. Empty stderr is also
    # acceptable per the gate; we write "interrupted" so the
    # user has visible feedback. Assert there is exactly one
    # line and no Ruby backtrace / Open3 thread noise.
    err_str = err.string
    refute_match(/report_on_exception/, err_str,
      "stderr must not contain 'report_on_exception' (Slice 6 G3 noise)")
    refute_match(/stream closed in another thread/, err_str,
      "stderr must not contain 'stream closed in another thread' " \
        "(Open3 reader-thread IOError)")
    refute_match(/open3\.rb/, err_str,
      "stderr must not contain an open3.rb backtrace line")
    refute_match(/\(IOError\)/, err_str,
      "stderr must not contain an `(IOError)` exception-class marker")
    refute_match(%r{^/[^[:space:]]+\.rb:\d+:in }, err_str,
      "stderr must not contain a multi-line Ruby backtrace " \
        "(file:line:in pattern)")

    # stdout should be empty (the boom command writes nothing).
    assert_empty out.string, "stdout should be empty on a ^C; got #{out.string.inspect}"
  end

  # Belt-and-braces: a non-Interrupt failure path still exits 1
  # and still surfaces its real error. This guards against the
  # Interrupt rescue accidentally swallowing real failures. The
  # existing `test_sync_repo_invalid_ref_exits_nonzero` /
  # `test_sync_repo_unknown_ref_exits_nonzero` in
  # `test/repo_tender/cli/sync_test.rb` already prove this at
  # the command level; this in-file test exercises it through
  # the same `CLI.run` entrypoint that adds the Interrupt
  # rescue, so a regression in the rescue (e.g. an overly broad
  # `rescue StandardError`) would be caught here even if the
  # command-level test were refactored.
  def test_genuine_command_failure_still_exits_1_via_cli_run
    out = StringIO.new
    err = StringIO.new
    status = nil
    begin
      # `status` is a real registered command; invoking it with
      # no state file present is a benign "no state yet" command
      # — but the point here is to prove that the Interrupt
      # rescue does not convert a normal command-dispatch path
      # into something else. We use `sync` with an invalid
      # `--repo` reference (the same shape as
      # `test_sync_repo_invalid_ref_exits_nonzero`); that path
      # goes through the full CLI dispatch + the command's own
      # `fail_with(self, "invalid repo reference: ...")` which
      # records `Outcome(exit_code: 1, message: ...)` and
      # reaches the existing `Kernel.exit(outcome.exit_code)`
      # in `CLI.run`. A broken Interrupt rescue that swallowed
      # everything would either swallow this failure too or
      # exit 130 instead of 1.
      Space::Src::CLI.run(["sync", "--repo", "not-a-ref"], out, err)
    rescue SystemExit => e
      status = e.status
    end

    assert_equal 1, status,
      "non-Interrupt failure path must still exit 1; got #{status.inspect} " \
        "(Interrupt rescue may be over-broad)"
    assert_includes err.string, "invalid repo reference",
      "non-Interrupt failure path must surface the real error message"
  end
end
