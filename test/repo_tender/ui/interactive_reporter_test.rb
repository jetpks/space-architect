# frozen_string_literal: true

require "test_helper"
require "stringio"

class InteractiveReporterTest < Minitest::Test
  IR = RepoTender::UI::InteractiveReporter
  Mode = RepoTender::UI::Mode

  REFS = [
    "github.com/owner/repo-a",
    "github.com/owner/repo-b",
    "github.com/owner/repo-c"
  ].freeze

  def make_reporter(out: nil, color: false, cadence: 0.01)
    out ||= StringIO.new
    mode = Mode.new(color: color, animate: true, quiet: false, format: :pretty)
    [IR.new(out, mode: mode, cadence: cadence), out]
  end

  # Drive the reporter through a mixed run: 1 cloned (clean), 1 dirty, 1 failed.
  def drive_reporter(reporter)
    reporter.run_started(total: REFS.size)
    REFS.each { |ref| reporter.repo_started(ref) }
    reporter.repo_phase(REFS[0], :cloning)
    reporter.repo_finished(REFS[0], "clean", action: :cloned, commits: 0)
    reporter.repo_phase(REFS[1], :fast_forwarding)
    reporter.repo_finished(REFS[1], "dirty", action: :dirty, commits: 0)
    reporter.repo_phase(REFS[2], :switching)
    reporter.repo_failed(REFS[2], "switch failed")
    reporter.run_finished("clean" => 1, "dirty" => 1, "error" => 1)
    reporter.detach
  end

  # ===========================================================================
  # G1 — No Ruby Thread spawned across attach→detach
  # ===========================================================================

  def test_g1_no_threads_created
    reporter, = make_reporter

    threads_before = nil
    threads_after = nil

    Sync do |task|
      threads_before = Thread.list.size
      reporter.attach(task)
      drive_reporter(reporter)
      threads_after = Thread.list.size
    end

    assert_equal threads_before, threads_after,
      "InteractiveReporter must not create any Ruby threads"
  end

  def test_g1_no_thread_new_in_source
    path = File.expand_path("../../../lib/repo_tender/ui/interactive_reporter.rb", __dir__)
    code_lines = File.readlines(path).reject { |l| l.strip.start_with?("#") }.join
    refute_match(/Thread\.(new|start|fork)/, code_lines,
      "interactive_reporter.rb must not call Thread.new/start/fork in code (comments excluded)")
  end

  # ===========================================================================
  # G2 — Render fiber is child of engine task; torn down by detach
  # ===========================================================================

  def test_g2_render_task_nil_after_detach
    reporter, = make_reporter

    Sync do |task|
      reporter.attach(task)
      reporter.run_started(total: 1)
      reporter.run_finished({})
      reporter.detach
    end

    assert_nil reporter.instance_variable_get(:@render_task),
      "render_task must be nil after detach"
  end

  def test_g2_cursor_show_emitted_on_detach
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      reporter.repo_started(REFS[0])
      reporter.repo_finished(REFS[0], "clean", action: :up_to_date)
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    assert_includes out.string, "\e[?25h",
      "cursor-show escape must be emitted on happy-path detach"
  end

  def test_g2_render_loop_suspends_between_repaints
    reporter, = make_reporter(cadence: 0.01)

    Sync do |task|
      reporter.attach(task)
      reporter.repo_started(REFS[0])
      sleep 0.05
      reporter.repo_finished(REFS[0], "clean", action: :up_to_date)
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    repaint_count = reporter.instance_variable_get(:@frame_idx)
    assert repaint_count > 1, "render loop must repaint more than once (was #{repaint_count})"
    assert repaint_count < 50, "render loop must not spin unconstrained (frame_idx=#{repaint_count})"
  end

  # ===========================================================================
  # GC1 — Bounded output: clean repos produce zero persistent lines;
  #        persistent count is independent of the clean count.
  # ===========================================================================

  def test_gc1_clean_repos_produce_no_persistent_lines
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      reporter.run_started(total: 1)
      reporter.repo_started(REFS[0])
      reporter.repo_finished(REFS[0], "clean", action: :up_to_date)
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    # Terminal block: summary + breakdown (up-to-date 1) = 2 newlines;
    # a clean repo adds no persistent line, no added-repos block.
    assert_equal 2, out.string.count("\n"),
      "a run with one clean repo must emit 2 newlines (summary + breakdown)"
  end

  def test_gc1_nonclean_repos_each_produce_one_persistent_line
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      drive_reporter(reporter)
    end

    # drive_reporter: 1 cloned (clean, no persistent), 1 dirty (⚠), 1 failed (✗).
    # Terminal: 2 persistent + 1 summary + 1 breakdown + 2 added-repos lines = 6 newlines.
    assert_equal 6, out.string.count("\n"),
      "expected 2 persistent + 1 summary + 1 breakdown + 2 added-repos = 6 newlines total"
  end

  def test_gc1_persistent_count_independent_of_clean_count
    nonclean = [
      ["github.com/o/dirty1", "dirty", :dirty],
      ["github.com/o/diverged1", "diverged", :diverged],
      ["github.com/o/wrong1", "wrong_branch", :wrong_branch],
      ["github.com/o/detached1", "detached", :detached]
    ]

    counts = [50, 5].map do |n_clean|
      out = StringIO.new
      mode = Mode.new(color: false, animate: true, quiet: false, format: :pretty)
      reporter = IR.new(out, mode: mode, cadence: 0.01)

      Sync do |task|
        total = n_clean + nonclean.size
        reporter.attach(task)
        reporter.run_started(total: total)
        n_clean.times do |i|
          ref = "github.com/o/clean-#{i}"
          reporter.repo_started(ref)
          reporter.repo_finished(ref, "clean", action: :up_to_date)
        end
        nonclean.each do |ref, status, action|
          reporter.repo_started(ref)
          reporter.repo_finished(ref, status, action: action)
        end
        reporter.run_finished({})
        reporter.detach
      end

      # Persistent lines start with ⚠/✗ immediately (no leading ANSI/status prefix).
      # They're flushed in render_sweep_tick (not the ensure), so split on \r\e[K
      # and count across ALL segments — the live status lines don't start with
      # ⚠/✗, only the persistent newline-terminated lines do.
      out.string.split("\r\e[K").sum { |seg|
        seg.split("\n").count { |l| l.match?(/\A[⚠✗]/) }
      }
    end

    assert_equal counts[0], counts[1],
      "persistent line count must not depend on clean count (50-clean: #{counts[0]}, 5-clean: #{counts[1]})"
    assert_equal nonclean.size, counts[0],
      "expected #{nonclean.size} persistent lines, got #{counts[0]}"
  end

  def test_gc1_no_cursor_up_in_output
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      drive_reporter(reporter)
    end

    refute_match(/\e\[\d+A/, out.string,
      "compact renderer must not emit cursor-up (\\e[<n>A) sequences")
  end

  # ===========================================================================
  # GC2 — Live counter, correct tallies, correct persistent set
  # ===========================================================================

  def test_gc2_status_line_contains_counter_and_tallies
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      drive_reporter(reporter)
    end

    result = out.string
    assert_match(/synced \d+\/#{REFS.size}/, result,
      "output must contain a status line with X/total counter")
    assert_match(/✓\s+\d+/, result, "output must contain ✓ tally")
    assert_match(/⚠\s+\d+/, result, "output must contain ⚠ tally")
    assert_match(/✗\s+\d+/, result, "output must contain ✗ tally")
  end

  def test_gc2_nonclean_persistent_lines_have_correct_content
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      drive_reporter(reporter)
    end

    result = out.string
    # dirty repo gets ⚠ persistent line with its ref and status
    assert_match(/⚠.*repo-b.*dirty/, result,
      "dirty repo must produce a ⚠ persistent line with ref and status")
    # failed repo gets ✗ persistent line with its error
    assert_match(/✗.*repo-c.*switch failed/, result,
      "failed repo must produce a ✗ persistent line with ref and error")
  end

  def test_gc2_clean_repo_has_no_persistent_line
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      drive_reporter(reporter)
    end

    # The clean repo (repo-a) must not appear in a ⚠ or ✗ persistent line.
    persistent_lines = out.string.split("\n").select { |l| l.match?(/[⚠✗]/) }
    refute persistent_lines.any? { |l| l.include?("repo-a") },
      "clean repo must not appear in any persistent line (found: #{persistent_lines.inspect})"
  end

  def test_gc2_final_summary_emitted_at_detach
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      drive_reporter(reporter)
    end

    # The last \n-terminated line (before cursor-show) is the summary.
    lines = out.string.split("\n")
    assert lines.any? { |l| l.include?("synced") && l.include?("clean") && l.include?("failed") },
      "final summary line must be emitted at detach (lines: #{lines.inspect})"
  end

  def test_gc2_tallies_match_outcomes
    refs_clean = %w[github.com/o/c1 github.com/o/c2]
    refs_nonclean = [["github.com/o/d1", "dirty", :dirty], ["github.com/o/w1", "wrong_branch", :wrong_branch]]
    refs_failed = [["github.com/o/f1", "boom"]]
    all_refs = refs_clean + refs_nonclean.map(&:first) + refs_failed.map(&:first)

    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      reporter.run_started(total: all_refs.size)
      refs_clean.each { |r|
        reporter.repo_started(r)
        reporter.repo_finished(r, "clean", action: :up_to_date)
      }
      refs_nonclean.each { |r, s, a|
        reporter.repo_started(r)
        reporter.repo_finished(r, s, action: a)
      }
      refs_failed.each { |r, e|
        reporter.repo_started(r)
        reporter.repo_failed(r, e)
      }
      reporter.run_finished({})
      reporter.detach
    end

    result = out.string
    # Persistent: 2 nonclean + 1 failed = 3, summary = 1, breakdown = 1 → 5 newlines
    assert_equal 5, result.count("\n"),
      "expected 3 persistent + 1 summary + 1 breakdown newlines, got #{result.count("\n")}"
    # Check that both nonclean refs appear as ⚠ lines
    assert_match(/⚠.*d1.*dirty/, result)
    assert_match(/⚠.*w1.*wrong_branch/, result)
    # Failed ref appears as ✗ line
    assert_match(/✗.*f1.*boom/, result)
    # Summary reflects all outcomes
    assert_match(/synced #{all_refs.size}\/#{all_refs.size}/, result)
  end

  # ===========================================================================
  # GC3 — Counter advances DURING the run (deterministic intermediate values)
  # ===========================================================================

  def test_gc3_counter_advances_intermediate_values
    refs = (0..3).map { |i| "github.com/o/r#{i}" }
    reporter, out = make_reporter(cadence: 0.01)

    Sync do |task|
      reporter.attach(task)
      reporter.run_started(total: refs.size)

      # Staggered completions: 20ms, 40ms, 60ms, 80ms.
      # Render cadence is 10ms → fires between completions.
      workers = refs.each_with_index.map do |ref, i|
        task.async do
          sleep 0.02 * (i + 1)
          reporter.repo_started(ref)
          reporter.repo_finished(ref, "clean", action: :up_to_date)
        end
      end
      workers.each(&:wait)

      reporter.run_finished("clean" => refs.size)
      reporter.detach
    end

    frames = out.string.scan(/synced (\d+)\/#{refs.size}/).map { |m| m[0].to_i }
    assert frames.any? { |x| x > 0 && x < refs.size },
      "counter must show intermediate values (> 0 and < #{refs.size}) before final tick; saw: #{frames.inspect}"
  end

  # ===========================================================================
  # G4 — Clean ^C teardown: cursor restored on render fiber ensure
  # ===========================================================================

  def test_g4_cursor_show_emitted_when_task_stopped
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task)
      reporter.repo_started(REFS[0])

      stopper = task.async do
        sleep 0.05
        reporter.instance_variable_get(:@render_task)&.stop
      end
      stopper.wait
    end

    assert_includes out.string, "\e[?25h",
      "cursor-show escape must be emitted when render task is stopped (^C path)"
  end

  def test_g4_no_live_fiber_after_task_stop
    reporter, = make_reporter

    Sync do |task|
      reporter.attach(task)
      reporter.repo_started(REFS[0])

      render_task = reporter.instance_variable_get(:@render_task)
      render_task&.stop
      sleep 0.02
    end

    render_task = reporter.instance_variable_get(:@render_task)
    assert render_task.nil? || !render_task.alive?,
      "render fiber must not be alive after task stop"
  end

  # ===========================================================================
  # G5 — Color gated by Mode; no SGR color codes when color=false
  # ===========================================================================

  def test_g5_color_off_no_sgr_codes
    reporter, out = make_reporter(color: false)

    Sync do |task|
      reporter.attach(task)
      drive_reporter(reporter)
    end

    result = out.string
    # Strip cursor-control escapes (hide/show; no cursor-up in compact model).
    stripped = result
      .gsub(/\e\[\?25[lh]/, "")
      .gsub(/\e\[\d+A/, "")
    refute_match(/\e\[[\d;]*m/, stripped,
      "no SGR color codes when mode.color == false; cursor movement codes are OK")
  end

  def test_g5_color_on_emits_sgr_codes
    reporter, out = make_reporter(color: true)

    Sync do |task|
      reporter.attach(task)
      reporter.repo_started(REFS[0])
      reporter.repo_finished(REFS[0], "clean", action: :up_to_date)
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    assert_match(/\e\[[\d;]*m/, out.string,
      "with mode.color == true, SGR color codes must appear in output")
  end

  def test_g5_still_animates_when_color_off
    reporter, out = make_reporter(color: false, cadence: 0.01)

    Sync do |task|
      reporter.attach(task)
      reporter.repo_started(REFS[0])
      sleep 0.05
      reporter.repo_finished(REFS[0], "clean", action: :up_to_date)
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    assert_includes out.string, "\e[?25l",
      "cursor-hide must be emitted even when color is off (animate still true)"
    assert_includes out.string, "\e[?25h",
      "cursor-show must be emitted even when color is off"
  end

  # ===========================================================================
  # GS6 — Two-phase: listing then sweep; both under one attach/detach.
  # ===========================================================================

  def test_gs6_listing_phase_emits_per_org_persistent_lines
    reporter, out = make_reporter(cadence: 0.01)
    orgs = [
      RepoTender::Config::OrgRef.new(host: "github.com", name: "org-a"),
      RepoTender::Config::OrgRef.new(host: "github.com", name: "org-b")
    ]

    Sync do |task|
      reporter.attach(task)
      reporter.listing_started(total: orgs.size)
      orgs.each_with_index do |org, i|
        reporter.org_listed(org, count: (i + 1) * 10)
      end
      reporter.listing_finished
      reporter.run_started(total: 1)
      reporter.repo_started(REFS[0])
      reporter.repo_finished(REFS[0], "clean", action: :up_to_date)
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    result = out.string
    # Persistent listing lines: one per org
    assert_match(/org-a/, result, "org-a must appear in listing output")
    assert_match(/org-b/, result, "org-b must appear in listing output")
    assert_match(/10/, result, "org-a count (10) must appear")
    assert_match(/20/, result, "org-b count (20) must appear")
    # Sweep summary still appears
    assert_match(/synced/, result, "sweep summary must appear after listing phase")
  end

  def test_gs6_listing_phase_failure_org_emits_failed_line
    reporter, out = make_reporter(cadence: 0.01)
    org = RepoTender::Config::OrgRef.new(host: "github.com", name: "bad-org")

    Sync do |task|
      reporter.attach(task)
      reporter.listing_started(total: 1)
      reporter.org_listed(org, count: nil)
      reporter.listing_finished
      reporter.run_started(total: 0)
      reporter.run_finished({})
      reporter.detach
    end

    result = out.string
    assert_match(/bad-org/, result)
    assert_match(/FAILED/, result)
  end

  def test_gs6_render_fiber_alive_across_both_phases
    reporter, = make_reporter(cadence: 0.01)
    org = RepoTender::Config::OrgRef.new(host: "github.com", name: "myorg")

    Sync do |task|
      reporter.attach(task)
      render_task_during_listing = reporter.instance_variable_get(:@render_task)
      refute_nil render_task_during_listing, "render task must be alive during listing phase"

      reporter.listing_started(total: 1)
      reporter.org_listed(org, count: 5)
      reporter.listing_finished
      reporter.run_started(total: 1)

      render_task_during_sweep = reporter.instance_variable_get(:@render_task)
      assert_equal render_task_during_listing, render_task_during_sweep,
        "same render task must be alive across both phases (no re-attach)"

      reporter.repo_finished(REFS[0], "clean", action: :up_to_date)
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    assert_nil reporter.instance_variable_get(:@render_task), "render task must be nil after detach"
  end

  def test_gs6_listing_output_bounded_by_org_count_not_repo_count
    # O(orgs) persistent lines in listing phase, O(non_clean) in sweep phase
    n_orgs = 3
    orgs = n_orgs.times.map { |i| RepoTender::Config::OrgRef.new(host: "github.com", name: "org#{i}") }
    n_clean_repos = 20  # many clean repos, zero persistent sweep lines

    reporter, out = make_reporter(cadence: 0.01)

    Sync do |task|
      reporter.attach(task)
      reporter.listing_started(total: n_orgs)
      orgs.each { |org| reporter.org_listed(org, count: 5) }
      reporter.listing_finished
      reporter.run_started(total: n_clean_repos)
      n_clean_repos.times do |i|
        reporter.repo_finished("github.com/o/clean#{i}", "clean", action: :up_to_date)
      end
      reporter.run_finished("clean" => n_clean_repos)
      reporter.detach
    end

    # n_orgs persistent listing lines + 1 summary + 1 breakdown = n_orgs + 2 newlines
    assert_equal n_orgs + 2, out.string.count("\n"),
      "output must be O(orgs + non_clean), not O(repos). Expected #{n_orgs + 2} newlines (#{n_orgs} listing + 1 summary + 1 breakdown)"
  end

  # ===========================================================================
  # GA1 + GA2 — Last org line must precede sweep ⚠ lines (ordering regression)
  # ===========================================================================

  def test_ga1_ga2_last_org_line_precedes_sweep_lines
    reporter, out = make_reporter(cadence: 0.01)
    orgs = [
      RepoTender::Config::OrgRef.new(host: "github.com", name: "first-org"),
      RepoTender::Config::OrgRef.new(host: "github.com", name: "last-org")
    ]
    dirty_ref = "github.com/owner/dirty-repo"

    Sync do |task|
      reporter.attach(task)
      # No sleep between events: the render fiber never ticks until detach
      # yields via @render_task.wait. Both org lines remain in @pending_org_lines
      # when run_started flips @phase to :sweep — the exact bug scenario.
      reporter.listing_started(total: orgs.size)
      orgs.each_with_index { |org, i| reporter.org_listed(org, count: (i + 1) * 10) }
      reporter.listing_finished
      reporter.run_started(total: 1)
      reporter.repo_finished(dirty_ref, "dirty", action: :dirty)
      reporter.run_finished("dirty" => 1)
      reporter.detach
    end

    # Strip all ANSI escape sequences, convert \r to \n, split into lines.
    cleaned = out.string
      .gsub(/\e\[\?\d+[lh]/, "")   # cursor hide/show: \e[?25l, \e[?25h
      .gsub(/\e\[[\d;]*[A-Za-z]/, "") # CSI sequences: \e[K, \e[nA, SGR, etc.
      .tr("\r", "\n")
    lines = cleaned.split("\n").map(&:strip).reject(&:empty?)

    last_org_idx = lines.rindex { |l| l.include?("last-org") }
    sweep_idx = lines.index { |l| l.include?("dirty") }

    refute_nil last_org_idx, "last-org must appear in output; lines=#{lines.inspect}"
    refute_nil sweep_idx, "dirty sweep line must appear in output; lines=#{lines.inspect}"
    assert last_org_idx < sweep_idx,
      "last org line (idx=#{last_org_idx}) must precede sweep ⚠ line (idx=#{sweep_idx})\nlines:\n#{lines.join("\n")}"
  end

  # ===========================================================================
  # G1 (interactive-status) — in-flight repo flashes on status line
  # ===========================================================================

  def test_g1_in_flight_verb_appears_and_clears_on_status_line
    reporter, out = make_reporter(color: false, cadence: 0.01)
    ref = "github.com/owner/repo-a"

    Sync do |task|
      reporter.attach(task)
      reporter.run_started(total: 1)

      reporter.repo_started(ref)
      sleep 0.05  # let render fire while "checking"

      reporter.repo_phase(ref, :cloning)
      sleep 0.05  # let render fire while "cloning"

      reporter.repo_phase(ref, :fast_forwarding)
      sleep 0.05  # let render fire while "fast-forwarding"

      reporter.repo_phase(ref, :switching)
      sleep 0.05  # let render fire while "switching"

      reporter.repo_finished(ref, "clean", action: :cloned)
      sleep 0.05  # let render fire after cleared

      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    # Collect live status-line content (between \r\e[K and next \r or \n)
    frames = out.string.scan(/\r\e\[K([^\r\n]*)/).map(&:first)

    assert frames.any? { |f| f.include?("checking") && f.include?("owner/repo-a") },
      "status line must show 'checking owner/repo-a' after repo_started\nframes:\n#{frames.join("\n")}"

    assert frames.any? { |f| f.include?("cloning") && f.include?("owner/repo-a") },
      "status line must show 'cloning owner/repo-a' after repo_phase(:cloning)\nframes:\n#{frames.join("\n")}"

    assert frames.any? { |f| f.include?("fast-forwarding") && f.include?("owner/repo-a") },
      "status line must show 'fast-forwarding owner/repo-a' after repo_phase(:fast_forwarding)\nframes:\n#{frames.join("\n")}"

    assert frames.any? { |f| f.include?("switching") && f.include?("owner/repo-a") },
      "status line must show 'switching owner/repo-a' after repo_phase(:switching)\nframes:\n#{frames.join("\n")}"

    # After repo_finished, the in-flight suffix must be absent from subsequent frames.
    # The render loop fires at least once after repo_finished (before detach's final tick).
    # frames.last is the final live tick — owner/repo-a must not appear as in-flight suffix.
    assert frames.any? { |f| !f.include?("owner/repo-a") },
      "at least one frame must not show 'owner/repo-a' as in-flight (e.g. after repo_finished)\nframes:\n#{frames.join("\n")}"
  end

  # ===========================================================================
  # G2 (interactive-status) — end-of-run breakdown + added-repos list
  # ===========================================================================

  def test_g2_end_summary_breakdown_and_added_repos_within_threshold
    reporter, out = make_reporter(color: false, cadence: 0.01)

    cloned_refs = %w[github.com/acme/new-a github.com/acme/new-b]
    ff_ref = "github.com/acme/ff-repo"
    utd_ref = "github.com/acme/current"
    dirty_ref = "github.com/acme/dirty-repo"
    err_ref = "github.com/acme/boom"
    all_refs = cloned_refs + [ff_ref, utd_ref, dirty_ref, err_ref]

    Sync do |task|
      reporter.attach(task)
      reporter.run_started(total: all_refs.size)
      cloned_refs.each do |r|
        reporter.repo_started(r)
        reporter.repo_phase(r, :cloning)
        reporter.repo_finished(r, "clean", action: :cloned, commits: 0)
      end
      reporter.repo_started(ff_ref)
      reporter.repo_phase(ff_ref, :fast_forwarding)
      reporter.repo_finished(ff_ref, "clean", action: :fast_forwarded, commits: 7)
      reporter.repo_started(utd_ref)
      reporter.repo_finished(utd_ref, "clean", action: :up_to_date, commits: 0)
      reporter.repo_started(dirty_ref)
      reporter.repo_finished(dirty_ref, "dirty", action: :dirty, commits: 0)
      reporter.repo_started(err_ref)
      reporter.repo_failed(err_ref, "network timeout")
      reporter.run_finished({})
      reporter.detach
    end

    # Extract terminal block (final output after last \r\e[K overwrite)
    terminal = out.string.split("\r\e[K").last.to_s

    # Breakdown assertions
    assert_match(/cloned.*2/, terminal, "breakdown must include 'cloned 2'")
    assert_match(/fast-forwarded/, terminal, "breakdown must include 'fast-forwarded'")
    assert_match(/7/, terminal, "breakdown must include commit count 7")
    assert_match(/commit/, terminal, "breakdown must include word 'commit'")
    assert_match(/up-to-date/, terminal, "breakdown must include 'up-to-date'")
    assert_match(/dirty/, terminal, "breakdown must include 'dirty'")
    assert_match(/error/, terminal, "breakdown must include 'error'")

    # Added-repos block: 2 cloned (≤ ADDED_LIST_THRESHOLD=10), both listed by owner/name
    assert_match(/added.*2/, terminal, "added-repos block must include count 2")
    assert_match(/acme\/new-a/, terminal, "added-repos block must list acme/new-a")
    assert_match(/acme\/new-b/, terminal, "added-repos block must list acme/new-b")
  end

  # ===========================================================================
  # G3 (interactive-status) — added-repos collapses above ADDED_LIST_THRESHOLD
  # ===========================================================================

  def test_g3_added_repos_collapses_above_threshold
    reporter, out = make_reporter(color: false, cadence: 0.01)
    n = IR::ADDED_LIST_THRESHOLD + 5  # 15

    Sync do |task|
      reporter.attach(task)
      reporter.run_started(total: n)
      n.times do |i|
        ref = format("github.com/owner/repo-%02d", i)
        reporter.repo_started(ref)
        reporter.repo_phase(ref, :cloning)
        reporter.repo_finished(ref, "clean", action: :cloned, commits: 0)
      end
      reporter.run_finished({})
      reporter.detach
    end

    terminal = out.string.split("\r\e[K").last.to_s

    assert_match(/added #{n} repos/, terminal,
      "should show 'added #{n} repos' one-line summary (above threshold)")
    refute_match(/owner\/repo-07/, terminal,
      "individual cloned names must NOT appear in terminal block above threshold")
  end
end
