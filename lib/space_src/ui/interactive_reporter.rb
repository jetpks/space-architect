# frozen_string_literal: true

require "pastel"
require "tty-cursor"

module Space::Src
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
      ADDED_LIST_THRESHOLD = 10
      IN_FLIGHT_MAX_WIDTH = 40

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

        # In-flight tracking (insertion-ordered: last entry = most-recently-started)
        @in_flight = {}

        # End-of-run breakdown state
        @action_counts = Hash.new(0)
        @total_commits = 0
        @added_repos = []

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

      def repo_started(ref)
        @in_flight[ref] = "checking"
      end

      def repo_phase(ref, phase)
        return unless @in_flight.key?(ref)
        @in_flight[ref] = case phase
        when :cloning then "cloning"
        when :fast_forwarding then "fast-forwarding"
        when :switching then "switching"
        else @in_flight[ref]
        end
      end

      def repo_finished(ref, status, action:, commits: 0)
        @in_flight.delete(ref)
        @finished += 1
        @action_counts[action] += 1
        @total_commits += commits
        @added_repos << ref if action == :cloned
        if status.to_s == "clean"
          @clean_count += 1
        else
          @nonclean_count += 1
          @pending_lines << "#{@pastel.yellow("⚠")} #{ref}  #{status}"
        end
      end

      def repo_failed(ref, error)
        @in_flight.delete(ref)
        @finished += 1
        @failed_count += 1
        @action_counts[:error] += 1
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
        breakdown = build_breakdown_line
        @out.write("#{breakdown}\n") unless breakdown.empty?
        added = build_added_repos_block
        @out.write(added) unless added.empty?
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
        # Right-justify every counter to the digit-width of @total (the cap on
        # all of them) so the in-flight suffix sits at a fixed column instead of
        # drifting right as counts cross digit boundaries. Padding is invisible
        # leading spaces.
        w = @total.to_s.length
        base = "#{frame} synced #{@finished.to_s.rjust(w)}/#{@total}   #{@pastel.green("✓")} #{@clean_count.to_s.rjust(w)}   #{@pastel.yellow("⚠")} #{@nonclean_count.to_s.rjust(w)}   #{@pastel.red("✗")} #{@failed_count.to_s.rjust(w)}"
        "#{base}#{build_in_flight_suffix}"
      end

      def build_summary_line
        "synced #{@finished}/#{@total}   #{@pastel.green("✓")} #{@clean_count} clean   #{@pastel.yellow("⚠")} #{@nonclean_count} non-clean   #{@pastel.red("✗")} #{@failed_count} failed"
      end

      def build_in_flight_suffix
        return "" if @in_flight.empty?
        ref, verb = @in_flight.to_a.last
        short = ref.to_s.split("/", 2).last.to_s
        short = short[0, IN_FLIGHT_MAX_WIDTH]
        "   · #{verb} #{short}"
      end

      def build_breakdown_line
        parts = []
        if (n = @action_counts[:cloned]) > 0
          parts << "cloned #{n}"
        end
        if (n = @action_counts[:fast_forwarded]) > 0
          commit_str = (@total_commits > 0) ? " (#{@total_commits} commit#{"s" unless @total_commits == 1})" : ""
          parts << "fast-forwarded #{n}#{commit_str}"
        end
        if (n = @action_counts[:up_to_date]) > 0
          parts << "up-to-date #{n}"
        end
        if (n = @action_counts[:switched]) > 0
          parts << "switched #{n}"
        end
        if (n = @action_counts[:dirty]) > 0
          parts << "dirty #{n}"
        end
        if (n = @action_counts[:diverged]) > 0
          parts << "diverged #{n}"
        end
        if (n = @action_counts[:wrong_branch]) > 0
          parts << "wrong-branch #{n}"
        end
        if (n = @action_counts[:detached]) > 0
          parts << "detached #{n}"
        end
        error_n = @action_counts[:error]
        if error_n > 0
          parts << "#{(error_n == 1) ? "error" : "errors"} #{error_n}"
        end
        parts.join("   ")
      end

      def build_added_repos_block
        return "" if @added_repos.empty?
        count = @added_repos.size
        if count > ADDED_LIST_THRESHOLD
          "added #{count} repos\n"
        else
          lines = ["added #{count} #{(count == 1) ? "repo" : "repos"}:"]
          @added_repos.each do |ref|
            short = ref.to_s.split("/", 2).last.to_s
            lines << "  #{short}"
          end
          lines.join("\n") + "\n"
        end
      end
    end
  end
end
