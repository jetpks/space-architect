# frozen_string_literal: true

require_relative "../test_helper"

class CodexImporterTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each do |t|
      conn[t].delete
    end
    @conv = Factory[:conversation]
    io = File.open(fixture_path("codex_rollout.jsonl"))
    Space::Server::Importers::Codex.new.import!(@conv, io)
    io.close
    @conv     = conversations_repo.by_pk(@conv.id)
    @messages = messages_repo.for_conversation(@conv.id)
  end

  def test_matches_predicate
    assert Space::Server::Importers::Codex.matches?({ "type" => "session_meta", "payload" => {} })
    refute Space::Server::Importers::Codex.matches?({ "type" => "user", "message" => {} })
    refute Space::Server::Importers::Codex.matches?(nil)
  end

  def test_source_and_status
    assert_equal "codex", @conv.source
    assert_equal :completed, @conv.status
  end

  def test_session_metadata
    assert_equal "sess-codex-1", @conv.session_id
    assert_equal "/tmp/space",   @conv.original_cwd
    assert_equal "0.133.0",      @conv.agent_version
    assert_nil @conv.git_branch
    assert_equal "fix the flappy alert", @conv.title
  end

  def test_message_count_roles_and_positions
    roles = @messages.map(&:role)
    types = @messages.map { |m| m.blocks.first["type"] }

    assert_equal 11, @messages.size
    assert_equal %w[user assistant assistant user assistant user assistant assistant user assistant user], roles
    assert_equal %w[text redacted_thinking tool_use tool_result tool_use tool_result tool_use tool_use tool_result text text], types
    assert_equal (0..10).to_a, @messages.map(&:position)
    assert_equal @messages.map(&:uuid), @messages.map(&:uuid).uniq
  end

  def test_model_stamped_on_assistant_rows_only
    assert_equal ["gpt-5.5"], @messages.select { |m| m.role == "assistant" }.map(&:model).uniq
    assert_equal [nil],       @messages.select { |m| m.role == "user" }.map(&:model).uniq
  end

  def test_function_call_arguments_parsed_into_tool_use_input
    exec = @messages[2].blocks.first
    assert_equal "exec_command", exec["name"]
    assert_equal "call_1",       exec["id"]
    assert_equal({ "cmd" => "ls -la", "workdir" => "/tmp/space" }, exec["input"])
  end

  def test_tool_result_pairs_to_call_id
    result = @messages[3].blocks.first
    assert_equal "call_1",   result["tool_use_id"]
    assert_equal "total 0",  result["content"]
  end

  def test_apply_patch_under_patch_key
    patch = @messages[4].blocks.first
    assert_equal "apply_patch", patch["name"]
    assert_includes patch["input"]["patch"], "*** Update File: /tmp/space/foo.rb"
  end

  def test_web_search_call_synthesizes_id
    search = @messages[6].blocks.first
    assert_equal "web_search", search["name"]
    assert_match(/\Acall-\d+\z/, search["id"])
  end

  def test_summaryless_encrypted_reasoning_is_redacted_thinking
    redacted = @messages[1].blocks.first
    assert_equal({ "type" => "redacted_thinking", "data" => "abc123==" }, redacted)
  end

  # Mirror of oracle: "imports reasoning with a summary as a thinking block"
  # A reasoning payload with a non-empty summary becomes type:"thinking",
  # not type:"redacted_thinking". The importer joins summary[].text and carries
  # encrypted_content as the signature.
  def test_reasoning_with_summary_becomes_thinking_block
    line = {
      timestamp: "2026-06-10T18:00:00.000Z",
      type: "response_item",
      payload: {
        type: "reasoning",
        summary: [{"text" => "weighing options"}],
        encrypted_content: "zzz=="
      }
    }.to_json

    conv = Factory[:conversation]
    Space::Server::Importers::Codex.new.import!(conv, StringIO.new(line))

    msgs = messages_repo.for_conversation(conv.id)
    assert_equal 1, msgs.size, "one message must be created from the reasoning line"
    thinking = msgs.first.blocks.first
    assert_equal(
      {"type" => "thinking", "thinking" => "weighing options", "signature" => "zzz=="},
      thinking,
      "reasoning with summary must become a thinking block"
    )
  end

  def test_turn_aborted_text_included
    # The final user message carries the <turn_aborted> text — not an env_context, so it's kept.
    last_user = @messages.last
    assert_equal "user", last_user.role
    assert last_user.blocks.first["text"].lstrip.start_with?("<turn_aborted>")
  end

  private

  def conversations_repo = Space::Server::Repos::ConversationsRepo.new
  def messages_repo      = Space::Server::Repos::MessagesRepo.new
  def fixture_path(name) = File.join(__dir__, "..", "fixtures", "files", name)
end
