# frozen_string_literal: true

require "open3"
require "async"
require "dry/monads"

module RepoTender
  # Thin Open3.capture3 wrapper that:
  #   * requires an ambient Async::Task (so subprocess I/O flows through
  #     Ruby's Fiber scheduler → kqueue on macOS and is non-blocking);
  #   * returns a Dry::Monads::Result — Success(stdout) on zero exit,
  #     Failure({argv:, stderr:, status:}) otherwise.
  #
  # Per AGENTS.md: no `async-process`. Per PRD §2: boundaries return
  # Result, exceptions are for programmer error only.
  class Shell
    extend Dry::Monads[:result]

    @run_count = 0
    @saved_roe = nil

    def self.run(*argv, chdir: nil, env: nil)
      raise ArgumentError, "Shell.run requires at least argv" if argv.empty?
      raise "Shell.run must be called inside an ambient Async::Task" unless Async::Task.current?

      full_env = env ? ENV.to_h.merge(env.transform_keys(&:to_s)) : nil
      opts = {}
      opts[:chdir] = chdir if chdir
      # Open3.capture3: env is a leading hash positional arg, not a kwarg.
      #
      # Open3.capture3 spawns the child with two internal reader
      # threads (one for stdout, one for stderr; see
      # `rubylibdir/open3.rb` ~L644: `out_reader = Thread.new { o.read }`
      # / `err_reader = Thread.new { e.read }`). When the `popen3`
      # block exits via exception (e.g. the user ^C'd mid-Shell.run
      # via SIGINT), `popen_run`'s ensure closes the read pipes from
      # the main thread while those reader threads are still inside
      # `o.read` / `e.read`. The mid-read close races with the reader
      # and raises `IOError: stream closed in another thread` in the
      # reader thread. With the default `Thread.report_on_exception
      # = true` (since Ruby 2.5), Ruby prints a multi-line backtrace
      # to stderr for that orphaned thread — exactly the noise
      # Slice 6 G3 silences.
      #
      # We bracket the `Open3.capture3` call with a save/restore of
      # `Thread.report_on_exception = false`. This is targeted
      # because, at this code site, the ONLY threads in flight are:
      #   * the main thread (this method's caller);
      #   * Async's internal `io_select` thread
      #     (`async/lib/async/scheduler.rb` L425) — which silences
      #     its own report (`Thread.current.report_on_exception =
      #     false` on that thread, not globally);
      #   * the Open3 reader threads (the source of the noise).
      # `lib/` has zero `Thread.new` calls; `dry-cli`, `dry-monads`,
      # `dry-validation`, `dry-struct`, `dry-types`, `dry-schema`,
      # `xdg` have none either (verified Slice 6 PHASE 0). So we are
      # NOT hiding any app-owned worker-thread crashes — the only
      # thread that can raise here is the Open3 reader thread, and
      # the only thing it can raise is the IOError we explicitly
      # want to silence. The original value is restored in `ensure`
      # so we never leak the suppression past this call.
      # Refcount the active Shell.run calls so the global flag is suppressed
      # for the entire overlapping window, not just per-fiber. On 0→1: capture
      # original and set false. On 1→0 (in ensure): restore the original.
      # Safe without a Mutex: the reactor is single-threaded; fibers only yield
      # at Open3.capture3's thread-join, never between these plain assignments.
      if @run_count == 0
        @saved_roe = Thread.report_on_exception
        Thread.report_on_exception = false
      end
      @run_count += 1
      begin
        stdout, stderr, status = if full_env
          Open3.capture3(full_env, *argv, **opts)
        else
          Open3.capture3(*argv, **opts)
        end
      ensure
        @run_count -= 1
        Thread.report_on_exception = @saved_roe if @run_count == 0
      end

      if status.success?
        Success(stdout)
      else
        Failure({argv: argv, stderr: stderr, status: status.exitstatus})
      end
    end
  end
end
