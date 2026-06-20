# frozen_string_literal: true

require "test_helper"
require "stringio"

class PlainReporterTest < Minitest::Test
  PlainReporter = SpaceArchitect::Pristine::UI::PlainReporter

  def make_reporter
    @out = StringIO.new
    PlainReporter.new(@out, mode: nil)
  end

  def test_repo_finished_emits_line_with_ref_and_status
    r = make_reporter
    r.repo_finished("github.com/foo/bar", "clean", action: :up_to_date)
    assert_includes @out.string, "github.com/foo/bar"
    assert_includes @out.string, "clean"
  end

  def test_repo_failed_emits_line_with_ref_and_failed_marker
    r = make_reporter
    r.repo_failed("github.com/foo/bar", "clone failed: timeout")
    assert_includes @out.string, "github.com/foo/bar"
    assert_includes @out.string, "FAILED"
    assert_includes @out.string, "clone failed: timeout"
  end

  def test_output_is_ansi_free
    r = make_reporter
    r.run_started(total: 3)
    r.repo_finished("github.com/foo/bar", "clean", action: :up_to_date)
    r.repo_failed("github.com/baz/qux", "error")
    r.run_finished({"clean" => 1, "error" => 1})
    refute_includes @out.string, "\e[", "PlainReporter must not emit ANSI escape sequences"
    refute_includes @out.string, "\x1b[", "PlainReporter must not emit ANSI escape sequences"
  end

  def test_attach_and_detach_produce_no_output
    r = make_reporter
    r.attach(nil)
    r.detach
    assert_empty @out.string, "attach/detach must produce no output"
  end

  def test_repo_started_produces_no_output
    r = make_reporter
    r.repo_started("github.com/foo/bar")
    assert_empty @out.string
  end

  def test_repo_phase_produces_no_output
    r = make_reporter
    r.repo_phase("github.com/foo/bar", :cloning)
    assert_empty @out.string
  end

  def test_run_started_emits_count
    r = make_reporter
    r.run_started(total: 4)
    assert_includes @out.string, "4"
  end

  def test_run_finished_produces_no_output
    r = make_reporter
    r.run_finished({"clean" => 2})
    assert_empty @out.string
  end

  def test_multiple_repos_each_get_a_line
    r = make_reporter
    r.repo_finished("github.com/a/b", "clean", action: :up_to_date)
    r.repo_finished("github.com/c/d", "dirty", action: :dirty)
    lines = @out.string.lines
    assert_equal 2, lines.size
    assert lines.any? { |l| l.include?("github.com/a/b") && l.include?("clean") }
    assert lines.any? { |l| l.include?("github.com/c/d") && l.include?("dirty") }
  end

  # GS5: output is immediately flushed on non-TTY (sync=true at construction)
  def test_out_sync_is_true_after_construction
    make_reporter
    assert @out.sync, "PlainReporter must set @out.sync = true for immediate non-TTY flush"
  end

  # GS5: listing events
  def test_listing_started_emits_org_count_line
    r = make_reporter
    r.listing_started(total: 3)
    assert_includes @out.string, "3"
    assert_includes @out.string, "org"
    refute_includes @out.string, "\e[", "listing_started must be ANSI-free"
  end

  def test_org_listed_success_emits_name_and_count
    r = make_reporter
    org_ref = SpaceArchitect::Pristine::Config::OrgRef.new(host: "github.com", name: "socketry")
    r.org_listed(org_ref, count: 42)
    assert_includes @out.string, "socketry"
    assert_includes @out.string, "42"
    refute_includes @out.string, "\e["
  end

  def test_org_listed_failure_emits_failed_marker
    r = make_reporter
    org_ref = SpaceArchitect::Pristine::Config::OrgRef.new(host: "github.com", name: "badorg")
    r.org_listed(org_ref, count: nil)
    assert_includes @out.string, "badorg"
    assert_includes @out.string, "FAILED"
    refute_includes @out.string, "\e["
  end

  def test_listing_finished_produces_no_output
    r = make_reporter
    r.listing_finished
    assert_empty @out.string
  end
end
