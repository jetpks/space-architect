# frozen_string_literal: true

require "pastel"
require "tty-cursor"

module RepoTender
  module UI
    # Compact, single-line live progress renderer for `sync`.
    # Driven by one render-loop fiber spawned as a child of the engine task
    # via `attach(task, total:)` — NO Ruby Thread.
    #
    # Output model:
    #   - One live status line, rewritten in place via \r + \e[K (never cursor.up(n)).
    #   - Persistent scrollback lines for NON-CLEAN repos only, emitted once each.
    #   - Clean repos increment the tally only — zero persistent lines.
    #   - Total output: O(non_clean + failed + constant), never O(N repos).
    #
    # Invariants:
    #   - The render fiber is the sole writer to `out`; worker fibers only
    #     mutate tally/queue state via the reporter event methods.
    #   - `Kernel#sleep` inside the render fiber yields to the reactor
    #     (cooperative scheduling). Never Thread.new.
    #   - On `^C`, the scheduler cancels the child render fiber; its `ensure`
    #     block restores the cursor unconditionally.
    class InteractiveReporter
      FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      def initialize(out, mode:, cadence: 0.1)
        @out = out
        @pastel = Pastel.new(enabled: mode.color)
        @cadence = cadence
        @total = 0
        @finished = 0
        @clean_count = 0
        @nonclean_count = 0
        @failed_count = 0
        @pending_lines = []
        @frame_idx = 0
        @done = false
        @render_task = nil
      end

      def attach(task, total:)
        @total = total
        @render_task = task.async { render_loop }
      end

      def detach
        @done = true
        @render_task&.wait
        @render_task = nil
      end

      def run_started(total:)
        @total = total
      end

      def repo_started(ref) = nil
      def repo_phase(ref, phase) = nil

      def repo_finished(ref, status)
        @finished += 1
        if status.to_s == "clean"
          @clean_count += 1
        else
          @nonclean_count += 1
          @pending_lines << "#{@pastel.yellow("⚠")} #{ref}  #{status}"
        end
      end

      def repo_failed(ref, error)
        @finished += 1
        @failed_count += 1
        @pending_lines << "#{@pastel.red("✗")} #{ref}  #{error}"
      end

      def run_finished(summary) = nil

      private

      def render_loop
        @out.write(TTY::Cursor.hide)
        @out.flush

        loop do
          render_tick
          @frame_idx += 1
          break if @done
          sleep @cadence
        end
      ensure
        pending = @pending_lines.slice!(0, @pending_lines.length)
        @out.write("\r\e[K")
        pending.each { |line| @out.write("#{line}\n") }
        @out.write("#{build_summary_line}\n")
        @out.write(TTY::Cursor.show)
        @out.flush
      end

      def render_tick
        pending = @pending_lines.slice!(0, @pending_lines.length)
        if pending.any?
          @out.write("\r\e[K")
          pending.each { |line| @out.write("#{line}\n") }
        end
        @out.write("\r\e[K#{build_status_line}")
      end

      def build_status_line
        frame = @pastel.cyan(FRAMES[@frame_idx % FRAMES.length])
        "#{frame} synced #{@finished}/#{@total}   #{@pastel.green("✓")} #{@clean_count}   #{@pastel.yellow("⚠")} #{@nonclean_count}   #{@pastel.red("✗")} #{@failed_count}"
      end

      def build_summary_line
        "synced #{@finished}/#{@total}   #{@pastel.green("✓")} #{@clean_count} clean   #{@pastel.yellow("⚠")} #{@nonclean_count} non-clean   #{@pastel.red("✗")} #{@failed_count} failed"
      end
    end
  end
end
