# frozen_string_literal: true

require "test_helper"

class SCMStatusTest < Minitest::Test
  Status = RepoTender::SCM::Status

  # Unit tests for the SCM::Status value object — a parsed porcelain-v2
  # representation. The end-to-end parsing of git output is exercised
  # by SCM::GitTest (real temp git repos).

  def test_clean_when_no_entries
    s = Status.new(clean: true, branch: "trunk", upstream: "origin/trunk", ahead: 0, behind: 0)
    assert s.clean?
    refute s.detached?
  end

  def test_dirty_when_entries_present
    s = Status.new(clean: false, entries: ["? new.txt"])
    refute s.clean?
  end

  def test_detached_flag_carries_through
    s = Status.new(clean: true, branch: "(detached)", detached: true)
    assert s.detached?
  end

  def test_ahead_behind_defaults
    s = Status.new(clean: true, branch: "trunk")
    assert_equal 0, s.ahead
    assert_equal 0, s.behind
  end
end
