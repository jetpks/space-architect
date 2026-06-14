# frozen_string_literal: true

require "pastel"
require "tty-cursor"
require "tty-screen"

module RepoTender
  module UI
    # Colorful, in-place, live progress renderer for `sync`.
    # Driven by one render-loop fiber spawned as a child of the engine task
    # via `attach(task, total:)` — NO Ruby Thread.
    #
    # Invariants:
    #   - The render fiber is the sole writer to `out`; worker fibers only
    #     mutate per-repo indicator state via the reporter event methods.
    #   - `Kernel#sleep` inside the render fiber yields to the reactor
    #     (cooperative scheduling). Never Thread.new.
    #   - On `^C`, the scheduler cancels the child render fiber; its `ensure`
    #     block restores the cursor unconditionally.
    class InteractiveReporter
      FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
      PHASE_LABELS = {
        cloning: "cloning",
        fast_forwarding: "fast-forwarding",
        switching: "switching"
      }.freeze
      LABEL_WIDTH = 32

      # @param out    [IO]      destination stream (real TTY in prod; StringIO in tests)
      # @param mode   [UI::Mode] resolved output mode
      # @param cadence [Float]  seconds between repaints (injectable for tests)
      def initialize(out, mode:, cadence: 0.1)
        @out = out
        @pastel = Pastel.new(enabled: mode.color)
        @refs = []
        @indicators = {}
        @render_task = nil
        @done = false
        @frame_idx = 0
        @cadence = cadence
      end

      # Spawn the render-loop fiber as a child of `task`. Called by the engine
      # before `run_started`, while still inside the `Sync{}` block.
      def attach(task, total:)
        @render_task = task.async { render_loop }
      end

      # Signal the render loop to exit, wait for the final repaint, and restore
      # the terminal. Called by the engine after `run_finished`.
      def detach
        @done = true
        @render_task&.wait
        @render_task = nil
      end

      def run_started(total:) = nil

      def repo_started(ref)
        @refs << ref unless @indicators.key?(ref)
        @indicators[ref] = {status: :started, phase: nil, final: nil}
      end

      def repo_phase(ref, phase)
        @indicators[ref]&.merge!(status: :phase, phase: phase)
      end

      def repo_finished(ref, status)
        @indicators[ref]&.merge!(status: :done, final: status.to_s)
      end

      def repo_failed(ref, error)
        @indicators[ref]&.merge!(status: :failed, error: error.to_s)
      end

      def run_finished(summary) = nil

      private

      def render_loop
        initialized = false
        n = 0

        begin
          @out.write(TTY::Cursor.hide)
          @out.flush

          loop do
            n = @refs.size

            if n > 0
              @out.write(TTY::Cursor.up(n)) if initialized
              width = [TTY::Screen.width, 40].max
              @refs.each { |ref| @out.write("\r#{format_line(ref).ljust(width)}\n") }
              @out.flush
              initialized = true
            end

            @frame_idx += 1
            break if @done
            sleep @cadence
          end
        ensure
          @out.write(TTY::Cursor.show)
          @out.puts
          @out.flush
        end
      end

      def format_line(ref)
        ind = @indicators[ref] || {status: :waiting}
        label = ref_label(ref)
        frame = FRAMES[@frame_idx % FRAMES.length]

        case ind[:status]
        when :waiting
          "  #{@pastel.dim("○")} #{label} #{@pastel.dim("waiting")}"
        when :started
          "  #{@pastel.yellow(frame)} #{label} #{@pastel.yellow("started")}"
        when :phase
          phase_str = PHASE_LABELS[ind[:phase]] || ind[:phase].to_s.tr("_", " ")
          "  #{@pastel.yellow(frame)} #{label} #{@pastel.cyan(phase_str)}"
        when :done
          "  #{@pastel.green("✓")} #{label} #{colorize_status(ind[:final], ind[:final])}"
        when :failed
          "  #{@pastel.red("✗")} #{label} #{@pastel.red("failed")}"
        else
          "  ? #{label}"
        end
      end

      def colorize_status(text, status)
        case status
        when "clean" then @pastel.green(text)
        when "error" then @pastel.red(text)
        else @pastel.yellow(text)
        end
      end

      def ref_label(ref)
        parts = ref.split("/")
        raw = parts.last(2).join("/")
        (raw.length > LABEL_WIDTH) ? "#{raw[0, LABEL_WIDTH - 3]}..." : raw.ljust(LABEL_WIDTH)
      end
    end
  end
end
