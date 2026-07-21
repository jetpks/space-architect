# frozen_string_literal: true

require_relative "../test_helper"

class SessionSyncSessionIdTest < Space::ArchitectTest
  SessionId = Space::Architect::SessionSync::SessionId

  # (a) pi shape: <mangled-cwd>/<timestamp>_<sessionId>.jsonl -> part after the last "_"
  def test_for_pi_takes_part_after_last_underscore
    path = "/home/user/.pi/agent/sessions/-Users-eric-project/20260101T120000_abc-123-def.jsonl"
    assert_equal "abc-123-def", SessionId.for_pi(path)
  end

  # (b) an underscore-bearing session id is still handled correctly (split on the LAST "_" only).
  def test_for_pi_handles_underscore_in_session_id
    path = "/x/20260101T120000_sess_with_underscore.jsonl"
    assert_equal "underscore", SessionId.for_pi(path)
  end

  # (c) claude shape: <mangled-cwd>/<sessionId>.jsonl -> basename minus ".jsonl"
  def test_for_claude_strips_jsonl_extension
    path = "/home/user/.claude/projects/-Users-eric-project/9f8c7b6a-1111-2222-3333-444455556666.jsonl"
    assert_equal "9f8c7b6a-1111-2222-3333-444455556666", SessionId.for_claude(path)
  end
end
