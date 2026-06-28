# frozen_string_literal: true

require_relative "support"

class NormalizerTest < Minitest::Test
  test "selects Opencode for record with part key" do
    assert_equal Space::Server::Normalizer::Opencode,
                 Space::Server::Normalizer.select("part" => {}, "type" => "step_start")
  end

  test "selects Opencode for record with sessionID (uppercase D)" do
    assert_equal Space::Server::Normalizer::Opencode,
                 Space::Server::Normalizer.select("sessionID" => "ses_abc")
  end

  test "selects ClaudeSession for session-log record with sessionId (camelCase)" do
    assert_equal Space::Server::Normalizer::ClaudeSession,
                 Space::Server::Normalizer.select("sessionId" => "aabbccdd-1111-2222-3333-444455556666",
                                                  "type" => "mode")
  end

  test "selects ClaudeCode as default" do
    assert_equal Space::Server::Normalizer::ClaudeCode,
                 Space::Server::Normalizer.select("type" => "system", "session_id" => "abc")
  end

  test "selects ClaudeCode for Claude Code first line from fixture" do
    line   = File.readlines(File.join(NORMALIZER_FIXTURE_DIR, "claude_code_stream_text.jsonl"), chomp: true).first
    record = JSON.parse(line)
    assert_equal Space::Server::Normalizer::ClaudeCode, Space::Server::Normalizer.select(record)
  end

  test "selects Opencode for opencode first line from fixture" do
    line   = File.readlines(File.join(NORMALIZER_FIXTURE_DIR, "opencode_stream_text.jsonl"), chomp: true).first
    record = JSON.parse(line)
    assert_equal Space::Server::Normalizer::Opencode, Space::Server::Normalizer.select(record)
  end
end
