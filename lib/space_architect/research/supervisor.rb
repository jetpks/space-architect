# frozen_string_literal: true

require "fileutils"
require "pathname"
require "time"

module Space::Architect
  module Research
    class Supervisor
      DEFAULT_MODEL     = Harness::DEFAULT_MODEL
      DEFAULT_MAX_TURNS = 40

      # The vendored builder-guard extension ships in the gem next to this file's
      # sibling pi/ dir — copied per-run and injected with the harness.
      VENDORED_GUARD = Pathname.new(__dir__).join("../pi/builder-guard.ts")

      def initialize(space:, bin: nil)
        @space    = space
        @bin      = bin
        @registry = Registry.new(space.path.join("build", "research", "registry.yaml"))
      end

      # Dispatch each prompt file as a detached pi child. Returns array of Run
      # objects (non-blocking).
      def dispatch(prompts, model: DEFAULT_MODEL, max_turns: DEFAULT_MAX_TURNS)
        prompts.map { |path| dispatch_one(Pathname.new(path), model: model, max_turns: max_turns) }
      end

      # Classify each registered run and return per-run state hashes.
      def status
        @registry.all.map do |run|
          state = classify(run)
          tail  = tail_lines(run.run_log_path, 5)
          { run: run, state: state, tail: tail }
        end
      end

      # Async mux: tail all runs to terminal. Returns :ok or :failed.
      def wait(quiet: false, level: 1, thinking: false, jsonl: false, out: $stdout)
        effective_level = quiet ? 0 : level
        renderer = Renderer.new(level: effective_level, thinking: thinking, jsonl: jsonl)
        runs = @registry.all
        return :ok if runs.empty?

        Mux.new(runs, renderer: renderer, out: out).run
      end

      private

      def dispatch_one(path, model:, max_turns:)
        id    = derive_id(path)
        topic = id.sub(/\A\d+-/, "")
        dir   = @space.path.join("build", "research", id)
        FileUtils.mkdir_p(dir)

        prompt_path  = dir.join("prompt.md")
        run_log_path = dir.join("run.jsonl")
        report_path  = dir.join("report.md")

        FileUtils.cp(path.to_s, prompt_path.to_s)

        # Vendor the guard into the run dir (idempotent overwrite) and inject it via
        # the harness — research runs get the same deny-only builder guard.
        guard_path = dir.join("builder-guard.ts")
        FileUtils.cp(VENDORED_GUARD, guard_path)

        # config_dir: is pi's --session-dir — research sessions land under
        # build/research/<id>/ instead of ~/.pi/agent/sessions/.
        harness = Harness::PiHarness.new(
          model:      model,
          max_turns:  max_turns,
          bin:        @bin,
          config_dir: dir,
          guard_path: guard_path
        )

        pid = harness.run_detached(
          prompt_path:  prompt_path,
          run_log_path: run_log_path,
          chdir:        @space.path
        )

        run = Run.new(
          id:            id,
          topic:         topic,
          pid:           pid,
          dir:           dir,
          prompt_path:   prompt_path,
          run_log_path:  run_log_path,
          report_path:   report_path,
          model:         model,
          dispatched_at: Time.now
        )
        @registry.add(run)
        run
      end

      def derive_id(path)
        File.basename(path.to_s).sub(/\.prompt\.md\z/, "").sub(/\.md\z/, "")
      end

      # pi has no terminal "result" event: the run's outcome is the LAST assistant
      # message's stopReason ("stop" finished normally; "error"/"aborted" failed —
      # pi's StopReason vocabulary; PiEvents is the one home for these
      # predicates). Without one, a live pid is still running and a dead pid
      # died without finishing.
      def classify(run)
        events = read_events(run.run_log_path)
        reason = PiEvents.stop_reason(events)

        return :complete if reason == "stop"
        return :failed   if PiEvents.failed_stop_reason?(reason)

        pid_alive = begin; Process.kill(0, run.pid); true; rescue Errno::ESRCH, Errno::EPERM; false; end
        pid_alive ? :running : :failed
      end

      def read_events(path)
        return [] unless File.exist?(path.to_s)
        File.readlines(path.to_s).filter_map { |l| JSON.parse(l.chomp) rescue nil }
      end

      def tail_lines(path, n)
        return [] unless File.exist?(path.to_s)
        File.readlines(path.to_s).last(n).map(&:chomp)
      end
    end
  end
end
