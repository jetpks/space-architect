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

  # Drive the reporter through a mixed run: 1 clean, 1 dirty, 1 failed.
  def drive_reporter(reporter)
    reporter.run_started(total: REFS.size)
    REFS.each { |ref| reporter.repo_started(ref) }
    reporter.repo_phase(REFS[0], :cloning)
    reporter.repo_finished(REFS[0], "clean")
    reporter.repo_phase(REFS[1], :fast_forwarding)
    reporter.repo_finished(REFS[1], "dirty")
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
      reporter.attach(task, total: REFS.size)
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
      reporter.attach(task, total: 1)
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
      reporter.attach(task, total: 1)
      reporter.repo_started(REFS[0])
      reporter.repo_finished(REFS[0], "clean")
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    assert_includes out.string, "\e[?25h",
      "cursor-show escape must be emitted on happy-path detach"
  end

  def test_g2_render_loop_suspends_between_repaints
    reporter, = make_reporter(cadence: 0.01)

    Sync do |task|
      reporter.attach(task, total: 1)
      reporter.repo_started(REFS[0])
      sleep 0.05
      reporter.repo_finished(REFS[0], "clean")
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
      reporter.attach(task, total: 1)
      reporter.run_started(total: 1)
      reporter.repo_started(REFS[0])
      reporter.repo_finished(REFS[0], "clean")
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    # Only the summary line ends with \n; a clean repo adds no persistent line.
    assert_equal 1, out.string.count("\n"),
      "a run with one clean repo must emit exactly 1 newline (the summary)"
  end

  def test_gc1_nonclean_repos_each_produce_one_persistent_line
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task, total: REFS.size)
      drive_reporter(reporter)
    end

    # 1 dirty (persistent ⚠) + 1 failed (persistent ✗) + 1 summary = 3 newlines.
    # 1 clean repo produces NO persistent line.
    assert_equal 3, out.string.count("\n"),
      "expected 2 persistent lines + 1 summary = 3 newlines total"
  end

  def test_gc1_persistent_count_independent_of_clean_count
    nonclean = [
      ["github.com/o/dirty1", "dirty"],
      ["github.com/o/diverged1", "diverged"],
      ["github.com/o/wrong1", "wrong_branch"],
      ["github.com/o/detached1", "detached"]
    ]

    counts = [50, 5].map do |n_clean|
      out = StringIO.new
      mode = Mode.new(color: false, animate: true, quiet: false, format: :pretty)
      reporter = IR.new(out, mode: mode, cadence: 0.01)

      Sync do |task|
        total = n_clean + nonclean.size
        reporter.attach(task, total: total)
        reporter.run_started(total: total)
        n_clean.times do |i|
          ref = "github.com/o/clean-#{i}"
          reporter.repo_started(ref)
          reporter.repo_finished(ref, "clean")
        end
        nonclean.each do |ref, status|
          reporter.repo_started(ref)
          reporter.repo_finished(ref, status)
        end
        reporter.run_finished({})
        reporter.detach
      end

      # persistent lines = total \n - 1 (summary)
      out.string.count("\n") - 1
    end

    assert_equal counts[0], counts[1],
      "persistent line count must not depend on clean count (50-clean: #{counts[0]}, 5-clean: #{counts[1]})"
    assert_equal nonclean.size, counts[0],
      "expected #{nonclean.size} persistent lines, got #{counts[0]}"
  end

  def test_gc1_no_cursor_up_in_output
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task, total: REFS.size)
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
      reporter.attach(task, total: REFS.size)
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
      reporter.attach(task, total: REFS.size)
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
      reporter.attach(task, total: REFS.size)
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
      reporter.attach(task, total: REFS.size)
      drive_reporter(reporter)
    end

    # The last \n-terminated line (before cursor-show) is the summary.
    lines = out.string.split("\n")
    assert lines.any? { |l| l.include?("synced") && l.include?("clean") && l.include?("failed") },
      "final summary line must be emitted at detach (lines: #{lines.inspect})"
  end

  def test_gc2_tallies_match_outcomes
    refs_clean = %w[github.com/o/c1 github.com/o/c2]
    refs_nonclean = [["github.com/o/d1", "dirty"], ["github.com/o/w1", "wrong_branch"]]
    refs_failed = [["github.com/o/f1", "boom"]]
    all_refs = refs_clean + refs_nonclean.map(&:first) + refs_failed.map(&:first)

    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task, total: all_refs.size)
      reporter.run_started(total: all_refs.size)
      refs_clean.each { |r|
        reporter.repo_started(r)
        reporter.repo_finished(r, "clean")
      }
      refs_nonclean.each { |r, s|
        reporter.repo_started(r)
        reporter.repo_finished(r, s)
      }
      refs_failed.each { |r, e|
        reporter.repo_started(r)
        reporter.repo_failed(r, e)
      }
      reporter.run_finished({})
      reporter.detach
    end

    result = out.string
    # Persistent lines: 2 nonclean + 1 failed = 3, plus 1 summary = 4 newlines
    assert_equal 4, result.count("\n"),
      "expected 3 persistent + 1 summary newlines, got #{result.count("\n")}"
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
      reporter.attach(task, total: refs.size)
      reporter.run_started(total: refs.size)

      # Staggered completions: 20ms, 40ms, 60ms, 80ms.
      # Render cadence is 10ms → fires between completions.
      workers = refs.each_with_index.map do |ref, i|
        task.async do
          sleep 0.02 * (i + 1)
          reporter.repo_started(ref)
          reporter.repo_finished(ref, "clean")
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
      reporter.attach(task, total: 2)
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
      reporter.attach(task, total: 1)
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
      reporter.attach(task, total: REFS.size)
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
      reporter.attach(task, total: 1)
      reporter.repo_started(REFS[0])
      reporter.repo_finished(REFS[0], "clean")
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    assert_match(/\e\[[\d;]*m/, out.string,
      "with mode.color == true, SGR color codes must appear in output")
  end

  def test_g5_still_animates_when_color_off
    reporter, out = make_reporter(color: false, cadence: 0.01)

    Sync do |task|
      reporter.attach(task, total: 1)
      reporter.repo_started(REFS[0])
      sleep 0.05
      reporter.repo_finished(REFS[0], "clean")
      reporter.run_finished("clean" => 1)
      reporter.detach
    end

    assert_includes out.string, "\e[?25l",
      "cursor-hide must be emitted even when color is off (animate still true)"
    assert_includes out.string, "\e[?25h",
      "cursor-show must be emitted even when color is off"
  end
end
