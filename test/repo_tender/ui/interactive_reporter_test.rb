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
      # Let the loop spin exactly a few times, then stop
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
  # G3 — N concurrent indicators advance independently; single-writer
  # ===========================================================================

  def test_g3_all_repos_appear_in_output
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task, total: REFS.size)
      drive_reporter(reporter)
    end

    REFS.each do |ref|
      short = ref.split("/").last(2).join("/")
      assert_includes out.string, short,
        "output must contain indicator for #{short}"
    end
  end

  def test_g3_output_has_one_cr_per_repo_per_repaint
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task, total: REFS.size)
      drive_reporter(reporter)
    end

    # Each indicator line is written with a leading \r (column-reset).
    # At minimum one repaint covers all 3 repos → at least 3 \r chars.
    assert out.string.count("\r") >= REFS.size,
      "expected at least #{REFS.size} \\r characters (one per repo per repaint)"
  end

  def test_g3_terminal_states_visible_in_final_output
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task, total: REFS.size)
      drive_reporter(reporter)
    end

    result = out.string
    assert_includes result, "clean"
    assert_includes result, "dirty"
    assert_includes result, "failed"
  end

  # ===========================================================================
  # G4 — Clean ^C teardown: cursor restored on render fiber ensure
  # ===========================================================================

  def test_g4_cursor_show_emitted_when_task_stopped
    reporter, out = make_reporter

    Sync do |task|
      reporter.attach(task, total: 2)
      reporter.repo_started(REFS[0])

      # Simulate interrupt: stop the render task mid-run by stopping
      # the subtask that contains the render fiber
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
      sleep 0.02  # let the ensure run
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
    # SGR color codes are \e[Nm where N is 30-37, 90-97 (fg) or 1;, 2; etc.
    # Cursor movement codes (\e[?25l, \e[?25h, \e[NA) are permitted.
    # Strip cursor-movement escapes and assert no color-SGR remains.
    stripped = result
      .gsub(/\e\[\?25[lh]/, "")   # cursor hide/show
      .gsub(/\e\[\d+A/, "")       # cursor up
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

    # Must contain cursor movement (animate=true) even with color off
    assert_includes out.string, "\e[?25l",
      "cursor-hide must be emitted even when color is off (animate still true)"
    assert_includes out.string, "\e[?25h",
      "cursor-show must be emitted even when color is off"
  end
end
