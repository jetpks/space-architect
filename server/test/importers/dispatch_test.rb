# frozen_string_literal: true

require_relative "../test_helper"

class ImportersDispatchTest < Minitest::Test
  def fixture_first_record(name)
    path = File.join(__dir__, "..", "fixtures", "files", name)
    File.open(path) do |f|
      f.each_line do |line|
        next if line.strip.empty?
        begin
          return JSON.parse(line)
        rescue JSON::ParserError
          next
        end
      end
    end
    nil
  end

  def test_selects_claude_code_for_transcript
    record = fixture_first_record("transcript.jsonl")
    assert_equal Space::Server::Importers::ClaudeCode, Space::Server::Importers.select(record)
  end

  def test_selects_codex_for_codex_rollout
    record = fixture_first_record("codex_rollout.jsonl")
    assert_equal Space::Server::Importers::Codex, Space::Server::Importers.select(record)
  end

  def test_selects_pi_for_pi_session
    record = fixture_first_record("pi_session.jsonl")
    assert_equal Space::Server::Importers::Pi, Space::Server::Importers.select(record)
  end

  def test_selects_pi_for_pi_streaming_session
    record = fixture_first_record("pi_streaming_session.jsonl")
    assert_equal Space::Server::Importers::Pi, Space::Server::Importers.select(record)
  end

  def test_nil_record_falls_back_to_claude_code
    assert_equal Space::Server::Importers::ClaudeCode, Space::Server::Importers.select(nil)
  end

  def test_unparseable_record_falls_back_to_claude_code
    assert_equal Space::Server::Importers::ClaudeCode, Space::Server::Importers.select("not a hash")
    assert_equal Space::Server::Importers::ClaudeCode, Space::Server::Importers.select(42)
  end

  def test_dispatcher_does_not_instantiate_importers
    # Verify select returns a Class, not an instance.
    result = Space::Server::Importers.select(nil)
    assert_equal Class, result.class
  end
end
