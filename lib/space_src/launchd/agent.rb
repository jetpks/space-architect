# frozen_string_literal: true

require "dry/monads"
require "async"
require "space_src/shell"
require "space_src/launchd/plist"

module Space::Src
  module Launchd
    # launchctl wrapper. Holds an injected command runner (the
    # real default goes through `Space::Src::Shell` inside a
    # `Sync{}` block; tests inject a `RecordingRunner` that
    # captures argv and returns canned output — gate G2).
    #
    # All public methods return `Dry::Monads::Result`. A non-zero
    # `launchctl` exit surfaces as `Failure({argv:, stderr:,
    # status:})` — the same shape `Shell.run` uses — NOT a
    # raise. A non-zero `runner` exit propagates as `Failure` to
    # the caller.
    #
    # Domain: every operation targets `gui/<UID>` (the user's
    # per-GUI-session launchd domain — the conventional domain
    # for user-installed LaunchAgents on macOS). The UID is
    # resolved via `Process.uid` by default; tests may inject
    # a different UID to assert the exact argv (G2).
    class Agent
      extend Dry::Monads[:result]

      DEFAULT_LABEL = "io.github.jetpks.repo-tender.sync"

      # The default real-runner. Wraps `Shell.run` in a `Sync{}`
      # block so the Fiber-scheduler requirement is satisfied.
      # Outside an ambient Async::Task, `Shell.run` would raise;
      # the wrapper creates one. This is the only place the
      # production code path touches `Shell` for launchctl.
      class ShellRunner
        def run(*argv, **opts)
          Sync do |_task|
            if opts.empty?
              Shell.run(*argv)
            else
              Shell.run(*argv, **opts)
            end
          end
        end
      end

      def initialize(runner: ShellRunner.new, uid: Process.uid, label: DEFAULT_LABEL)
        @runner = runner
        @uid = uid
        @label = label
      end

      attr_reader :label

      # `launchctl bootstrap gui/<UID> <abs-plist-path>`
      def install(plist_path)
        run("bootstrap", "gui/#{@uid}", plist_path)
      end

      # `launchctl bootout gui/<UID>/<label>`
      #
      # Idempotency (Slice 5 / CF5): a benign bootout Failure
      # (status 3 / "No such process" / "Could not find
      # specified service") is mapped to **Success** —
      # uninstalling a not-loaded agent is a no-op for the
      # bootout step. The plist removal in the CLI command
      # layer is independent of this result.
      def uninstall
        r = run("bootout", "gui/#{@uid}/#{@label}")
        return Dry::Monads::Success("") if benign_bootout_failure?(r)
        r
      end

      # bootstrap the plist, then `enable` the service.
      # Both must succeed (both 0 exit) for the operation to
      # be a `Success`; the first failure short-circuits.
      def start(plist_path)
        r1 = run("bootstrap", "gui/#{@uid}", plist_path)
        return r1 if r1.failure?
        run("enable", "gui/#{@uid}/#{@label}")
      end

      # bootout the service, then `disable` it.
      #
      # Idempotency (Slice 5 / CF5): a `bootout` Failure with
      # `status == 3` ("No such process") or matching the
      # not-loaded stderr is treated as **already not loaded**
      # and is not propagated — the disable step still runs so
      # the persistent `disable` override stays in place
      # (matching the gate's recorded-argv assertion
      # `[[bootout,…], [disable,…]]` and the
      # "stopped" semantic). A non-benign bootout Failure
      # (e.g. status 1 "Operation not permitted") short-
      # circuits as before.
      def stop
        r1 = run("bootout", "gui/#{@uid}/#{@label}")
        return r1 if r1.failure? && !benign_bootout_failure?(r1)
        run("disable", "gui/#{@uid}/#{@label}")
      end

      # `launchctl kickstart -k gui/<UID>/<label>` — `-k` kills
      # the running instance first so the new one always starts.
      def restart
        run("kickstart", "-k", "gui/#{@uid}/#{@label}")
      end

      # Returns a defensive parse of `launchctl list` (the
      # machine-readable form — `launchctl print` is documented
      # as "not API"). We run `launchctl list` (no service
      # target) and search the output for our label.
      #
      # The parser tolerates: empty output, a "Could not find"
      # line, malformed rows, and PID values that are not
      # integers. On any of those, we return Success(loaded:
      # false) — the gate G4 "no raise on malformed" guarantee.
      def status
        result = run("list")
        return result if result.failure?
        parse_list(result.success)
      end

      # ----- internal: argv dispatch + list parser -----

      private

      # CF5: a `bootout` Failure whose `status == 3` ("No such
      # process") OR whose stderr matches the
      # not-loaded markers is **not a real failure** — the
      # service is simply not currently loaded, which is the
      # common case at a 6h refresh interval. We key on
      # `argv[1] == "bootout"` so the benign mapping is
      # strictly scoped to bootout (bootstrap status-3
      # remains a real Failure — gate G3 regression guard).
      #
      # Status 3 is the POSIX `ESRCH` errno (`launchctl error 3`
      # → "No such process") and is the documented signal.
      # The stderr regex is the defensive OR — `launchctl`
      # stderr text is NOT API and may drift; we accept both
      # observed phrasings ("No such process" from recent
      # macOS, "Could not find specified service" from older
      # releases / the legacy `unload` path).
      def benign_bootout_failure?(result)
        return false unless result.failure?

        f = result.failure
        return false unless f.is_a?(Hash)

        argv = f[:argv]
        return false unless argv.is_a?(Array) && argv[1] == "bootout"

        return true if f[:status] == 3
        stderr = f[:stderr].to_s
        stderr.match?(/No such process|Could not find specified service/i)
      end

      # Every operation is a `launchctl` subcommand — the program
      # name must be argv[0] so the runner (real `Shell.run` →
      # Open3) actually execs `launchctl`, not the bare subcommand.
      def run(*argv)
        @runner.run("launchctl", *argv)
      end

      # Parses the tabular output of `launchctl list`. Each line
      # is three tab-separated fields: PID, Status (last exit
      # code), Label. PID is "-" if the job is not currently
      # running. A line whose label matches ours is the row we
      # want; everything else is ignored.
      def parse_list(output)
        return Dry::Monads::Success({loaded: false, running: false, last_exit: nil, pid: nil}) if output.nil? || output.empty?

        output.each_line do |line|
          fields = line.chomp.split("\t", 3)
          next if fields.length < 3
          pid_s, status_s, lbl = fields
          next unless lbl == @label
          pid = (pid_s == "-" || pid_s.nil? || pid_s.empty?) ? nil : Integer(pid_s, exception: false)
          status = (status_s == "-" || status_s.nil? || status_s.empty?) ? nil : Integer(status_s, exception: false)
          return Dry::Monads::Success({
            loaded: true,
            running: !pid.nil?,
            pid: pid,
            last_exit: status
          })
        end

        Dry::Monads::Success({loaded: false, running: false, last_exit: nil, pid: nil})
      rescue => e
        # Defensive: any unexpected parse failure is reported as
        # "unknown" — NOT a raise (gate G4).
        Dry::Monads::Success({loaded: false, running: false, last_exit: nil, pid: nil, error: e.message})
      end
    end
  end
end
