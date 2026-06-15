# frozen_string_literal: true

require "pastel"
require "tty-cursor"

module RepoTender
  module UI
    # Compact, single-line live progress renderer for `sync`.
    # Driven by one render-loop fiber spawned as a child of the engine task
    # via `attach(task)` — NO Ruby Thread.
    #
    # Two phases under one attach/detach (GS6):
    #
    #   Phase 1 — Listing: fires between listing_started and listing_finished.
    #     Live status line shows "listing N orgs… ✓ K done". As each org
    #     completes, a persistent line is emitted (org name + count).
    #
    #   Phase 2 — Sweep: fires after run_started through run_finished.
    #     Reverts to the compact repo counter (synced X/N + tallies).
    #
    # Output model:
    #   - One live status line, rewritten in place via \r + \e[K.
    #   - Persistent scrollback lines for listing phase (one per org) and
    #     for NON-CLEAN repos only in sweep phase.
    #   - Total output: O(orgs + non_clean + failed + constant).
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

        # Listing phase state
        @org_total = 0
        @org_done = 0
        @pending_org_lines = []

        # Sweep phase state
        @total = 0
        @finished = 0
        @clean_count = 0
        @nonclean_count = 0
        @failed_count = 0
        @pending_lines = []

        @frame_idx = 0
        @phase = :listing  # :listing | :sweep
        @done = false
        @render_task = nil
      end

      def attach(task)
        @render_task = task.async { render_loop }
      end

      def detach
        @done = true
        @render_task&.wait
        @render_task = nil
      end

      # --- Listing phase events ---

      def listing_started(total:)
        @org_total = total
        @phase = :listing
      end

      def org_listed(ref, count:)
        @org_done += 1
        @pending_org_lines << if count
          "#{@pastel.green("✓")} #{ref.name}  #{count} repo(s)"
        else
          "#{@pastel.red("✗")} #{ref.name}  FAILED"
        end
      end

      def listing_finished
        # Phase transition handled by run_started
      end

      # --- Sweep phase events ---

      def run_started(total:)
        @total = total
        @phase = :sweep
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
        # Flush any remaining org lines (listing phase may have ended without
        # a final tick draining them).
        pending_org = @pending_org_lines.slice!(0, @pending_org_lines.length)
        pending = @pending_lines.slice!(0, @pending_lines.length)
        @out.write("\r\e[K")
        pending_org.each { |line| @out.write("#{line}\n") }
        pending.each { |line| @out.write("#{line}\n") }
        @out.write("#{build_summary_line}\n")
        @out.write(TTY::Cursor.show)
        @out.flush
      end

      def render_tick
        if @phase == :listing
          render_listing_tick
        else
          render_sweep_tick
        end
      end

      def render_listing_tick
        pending = @pending_org_lines.slice!(0, @pending_org_lines.length)
        if pending.any?
          @out.write("\r\e[K")
          pending.each { |line| @out.write("#{line}\n") }
        end
        frame = @pastel.cyan(FRAMES[@frame_idx % FRAMES.length])
        @out.write("\r\e[K#{frame} listing #{@org_total} org(s)…  #{@pastel.green("✓")} #{@org_done} done")
      end

      def render_sweep_tick
        org_pending = @pending_org_lines.slice!(0, @pending_org_lines.length)
        if org_pending.any?
          @out.write("\r\e[K")
          org_pending.each { |line| @out.write("#{line}\n") }
        end
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
