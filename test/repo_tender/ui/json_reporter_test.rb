# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

class JsonReporterTest < Minitest::Test
  JsonReporter = RepoTender::UI::JsonReporter

  def make_reporter
    @out = StringIO.new
    JsonReporter.new(@out)
  end

  def lines
    @out.string.lines.map(&:chomp).reject(&:empty?)
  end

  def parsed_lines
    lines.map { |l| JSON.parse(l) }
  end

  def test_each_emitted_line_is_parseable_json
    r = make_reporter
    r.run_started(total: 2)
    r.repo_started("github.com/foo/bar")
    r.repo_phase("github.com/foo/bar", :cloning)
    r.repo_finished("github.com/foo/bar", "clean", action: :cloned)
    r.run_finished({"clean" => 1})
    parsed_lines.each_with_index do |obj, i|
      assert obj.is_a?(Hash), "line #{i} should parse to a Hash"
    end
  end

  def test_repo_finished_has_event_ref_status_and_timestamp
    r = make_reporter
    r.repo_finished("github.com/foo/bar", "clean", action: :cloned, commits: 0)
    obj = JSON.parse(lines.last)
    assert_equal "repo_finished", obj["event"]
    assert_equal "github.com/foo/bar", obj["ref"]
    assert_equal "clean", obj["status"]
    assert obj.key?("t"), "must include timestamp key 't'"
    assert_equal "cloned", obj["action"]
    assert_equal 0, obj["commits"]
  end

  def test_repo_failed_has_event_ref_and_error
    r = make_reporter
    r.repo_failed("github.com/foo/bar", "clone failed")
    obj = JSON.parse(lines.last)
    assert_equal "repo_failed", obj["event"]
    assert_equal "github.com/foo/bar", obj["ref"]
    assert obj.key?("error")
    assert_includes obj["error"], "clone failed"
  end

  def test_run_started_has_event_and_total
    r = make_reporter
    r.run_started(total: 5)
    obj = JSON.parse(lines.last)
    assert_equal "run_started", obj["event"]
    assert_equal 5, obj["total"]
  end

  def test_run_finished_has_event_and_summary
    r = make_reporter
    r.run_finished({"clean" => 3, "dirty" => 1})
    obj = JSON.parse(lines.last)
    assert_equal "run_finished", obj["event"]
    assert_equal 3, obj["summary"]["clean"]
    assert_equal 1, obj["summary"]["dirty"]
  end

  def test_repo_phase_has_event_ref_and_phase
    r = make_reporter
    r.repo_phase("github.com/foo/bar", :fast_forwarding)
    obj = JSON.parse(lines.last)
    assert_equal "repo_phase", obj["event"]
    assert_equal "github.com/foo/bar", obj["ref"]
    assert_equal "fast_forwarding", obj["phase"]
  end

  def test_one_json_object_per_event
    r = make_reporter
    r.run_started(total: 1)
    r.repo_started("github.com/foo/bar")
    r.repo_phase("github.com/foo/bar", :cloning)
    r.repo_finished("github.com/foo/bar", "clean", action: :cloned)
    r.run_finished({"clean" => 1})
    assert_equal 5, lines.size
    assert_equal 5, parsed_lines.size
  end

  def test_attach_and_detach_produce_no_output
    r = make_reporter
    r.attach(nil)
    r.detach
    assert_empty @out.string
  end

  # GS5: output is immediately flushed on non-TTY (sync=true at construction)
  def test_out_sync_is_true_after_construction
    make_reporter
    assert @out.sync, "JsonReporter must set @out.sync = true for immediate non-TTY flush"
  end

  # GS5: listing events emit parseable JSON objects
  def test_listing_started_emits_json_with_total
    r = make_reporter
    r.listing_started(total: 5)
    obj = JSON.parse(lines.last)
    assert_equal "listing_started", obj["event"]
    assert_equal 5, obj["total"]
  end

  def test_org_listed_emits_json_with_org_and_count
    r = make_reporter
    org_ref = RepoTender::Config::OrgRef.new(host: "github.com", name: "socketry")
    r.org_listed(org_ref, count: 42)
    obj = JSON.parse(lines.last)
    assert_equal "org_listed", obj["event"]
    assert_equal "socketry", obj["org"]
    assert_equal 42, obj["count"]
  end

  def test_org_listed_failure_emits_null_count
    r = make_reporter
    org_ref = RepoTender::Config::OrgRef.new(host: "github.com", name: "badorg")
    r.org_listed(org_ref, count: nil)
    obj = JSON.parse(lines.last)
    assert_equal "org_listed", obj["event"]
    assert_equal "badorg", obj["org"]
    assert_nil obj["count"]
  end

  def test_listing_finished_emits_json_event
    r = make_reporter
    r.listing_finished
    obj = JSON.parse(lines.last)
    assert_equal "listing_finished", obj["event"]
  end
end
