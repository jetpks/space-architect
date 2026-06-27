# frozen_string_literal: true

require "fileutils"
require "time"

module Space::Architect
  module Research
    class Supervisor
      DEFAULT_MODEL     = Harness::CLAUDE_DEFAULT_MODEL
      DEFAULT_MAX_TURNS = 40

      def initialize(space:, bin: nil)
        @space    = space
        @bin      = bin
        @registry = Registry.new(space.path.join("build", "research", "registry.yaml"))
      end

      # Dispatch each prompt file as a detached read-only claude -p child.
      # Returns array of Run objects (non-blocking).
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

        harness = Harness::ClaudeCodeHarness.new(
          model:            model,
          max_turns:        max_turns,
          bin:              @bin,
          allowed_tools:    READONLY_TOOLS,
          disallowed_tools: ""
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

      def classify(run)
        content = File.exist?(run.run_log_path.to_s) ? File.read(run.run_log_path.to_s) : ""
        events  = content.lines.filter_map { |l| JSON.parse(l.chomp) rescue nil }
        terminal = events.find { |e| e["type"] == "result" }

        return :complete if terminal && !terminal["is_error"]
        return :failed   if terminal && terminal["is_error"]

        pid_alive = begin; Process.kill(0, run.pid); true; rescue Errno::ESRCH, Errno::EPERM; false; end
        pid_alive ? :running : :failed
      end

      def tail_lines(path, n)
        return [] unless File.exist?(path.to_s)
        File.readlines(path.to_s).last(n).map(&:chomp)
      end
    end
  end
end
