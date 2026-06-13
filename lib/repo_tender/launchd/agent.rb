# frozen_string_literal: true

require "dry/monads"
require "async"
require "repo_tender/shell"
require "repo_tender/launchd/plist"

module RepoTender
  module Launchd
    # launchctl wrapper. Holds an injected command runner (the
    # real default goes through `RepoTender::Shell` inside a
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
      def uninstall
        run("bootout", "gui/#{@uid}/#{@label}")
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
      def stop
        r1 = run("bootout", "gui/#{@uid}/#{@label}")
        return r1 if r1.failure?
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

      def run(*argv)
        @runner.run(*argv)
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
