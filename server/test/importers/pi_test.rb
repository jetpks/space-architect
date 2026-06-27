# frozen_string_literal: true

require_relative "../test_helper"

class PiImporterTreeTest < Minitest::Test
  def conn
    @conn ||= Architect::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each do |t|
      conn[t].delete
    end
    @conv = Factory[:conversation]
    io = File.open(fixture_path("pi_session.jsonl"))
    Architect::Importers::Pi.new.import!(@conv, io)
    io.close
    @conv     = conversations_repo.by_pk(@conv.id)
    @messages = messages_repo.for_conversation(@conv.id)
  end

  def test_matches_predicate
    assert Architect::Importers::Pi.matches?({ "type" => "session", "version" => 3 })
    assert Architect::Importers::Pi.matches?({ "type" => "message", "id" => "a", "parentId" => nil, "message" => {} })
    assert Architect::Importers::Pi.matches?({ "type" => "model_change", "id" => "a", "parentId" => nil, "provider" => "p", "modelId" => "m" })
    assert Architect::Importers::Pi.matches?({ "type" => "compaction", "id" => "a", "parentId" => "b", "summary" => "..." })
    refute Architect::Importers::Pi.matches?({ "type" => "session_meta", "payload" => {} })
    refute Architect::Importers::Pi.matches?({ "type" => "user", "message" => {} })
    refute Architect::Importers::Pi.matches?({ "type" => "message", "message" => {} }) # missing id/parentId
    refute Architect::Importers::Pi.matches?(nil)
  end

  def test_matches_streaming_lifecycle_events
    assert Architect::Importers::Pi.matches?({ "type" => "agent_start" })
    assert Architect::Importers::Pi.matches?({ "type" => "turn_start" })
    assert Architect::Importers::Pi.matches?({ "type" => "message_start" })
    assert Architect::Importers::Pi.matches?({ "type" => "message_end", "message" => {} })
    # Codex envelope still wins
    refute Architect::Importers::Pi.matches?({ "type" => "message_start", "payload" => {} })
  end

  def test_source_status_metadata_and_title
    assert_equal "pi",          @conv.source
    assert_equal :completed,    @conv.status
    assert_equal "pi-sess-1",   @conv.session_id
    assert_equal "/tmp/pi-project", @conv.original_cwd
    assert_equal "review the auth flow and add tests", @conv.title
  end

  def test_message_count_and_chronological_order
    assert_equal 9, @messages.size
    assert_equal [0, 1, 2, 3, 4, 5, 6, 7, 8], @messages.map(&:position)
    assert_equal %w[user assistant assistant assistant user user assistant user assistant], @messages.map(&:role)
  end

  def test_normalizes_user_text_message
    first = @messages[0]
    assert_equal [{ "type" => "text", "text" => "review the auth flow and add tests" }], first.blocks
  end

  def test_assistant_thinking_becomes_text_block
    text_message = @messages.find { |m| m.uuid == "a0000004" }
    assert text_message
    assert_equal %w[text text], text_message.blocks.map { |b| b["type"] }
    assert_equal "I'll review the auth flow first.", text_message.blocks.first["text"]
  end

  def test_splits_assistant_into_text_lead_and_per_tool_messages
    text_message = @messages.find { |m| m.uuid == "a0000004" }
    tool_messages = @messages.select { |m| m.uuid.to_s.start_with?("a0000004-tools") }

    assert text_message
    assert_equal 2, tool_messages.size
    tool_messages.each do |tm|
      assert_equal "assistant", tm.role
      assert_equal ["tool_use"], tm.blocks.map { |b| b["type"] }
    end
    assert_equal ["read", "bash"], tool_messages.map { |m| m.blocks.first["name"] }
  end

  def test_model_stamped_on_split_assistant_messages
    text_message = @messages.find { |m| m.uuid == "a0000004" }
    tool_messages = @messages.select { |m| m.uuid.to_s.start_with?("a0000004-tools") }

    assert_equal "moonshotai/kimi-k2.7-code", text_message.model
    tool_messages.each { |tm| assert_equal "moonshotai/kimi-k2.7-code", tm.model }
  end

  def test_normalizes_tool_results
    results = @messages.select { |m| m.blocks.any? { |b| b["type"] == "tool_result" } }
    assert_equal 2, results.size
    by_id = results.to_h { |m| [m.blocks.first["tool_use_id"], m.blocks.first] }
    assert_includes by_id["call_1"]["content"], "class SessionsController"
    assert_includes by_id["call_2"]["content"], "sessions_controller_test.rb"
    assert_equal false, by_id["call_1"]["is_error"]
  end

  def test_normalizes_bash_execution_to_command_envelope
    bash = @messages.find { |m| m.blocks.any? { |b| b["type"] == "text" && b["text"].include?("<command-name>bash</command-name>") } }
    assert bash
    assert_equal "user", bash.role
    text = bash.blocks.first["text"]
    assert_includes text, "<command-name>bash</command-name>"
    assert_includes text, "<command-args>ls test/controllers</command-args>"
    assert_includes text, "<local-command-stdout>"
    assert_includes text, "sessions_controller_test.rb"
  end

  def test_final_assistant_terminal_message
    terminal = @messages.last
    assert_equal "assistant", terminal.role
    assert_equal "Done. I added tests for the OAuth callback and failure paths.", terminal.blocks.first["text"]
  end

  private

  def conversations_repo = Architect::Repos::ConversationsRepo.new
  def messages_repo      = Architect::Repos::MessagesRepo.new
  def fixture_path(name) = File.join(__dir__, "..", "fixtures", "files", name)
end

class PiImporterStreamingTest < Minitest::Test
  def conn
    @conn ||= Architect::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each do |t|
      conn[t].delete
    end
    @conv = Factory[:conversation]
    io = File.open(fixture_path("pi_streaming_session.jsonl"))
    Architect::Importers::Pi.new.import!(@conv, io)
    io.close
    @conv     = conversations_repo.by_pk(@conv.id)
    @messages = messages_repo.for_conversation(@conv.id)
  end

  def test_completes_and_imports_messages
    assert_equal :completed, @conv.status
    assert_operator @messages.size, :>, 0
    assert_equal (0..(@messages.size - 1)).to_a, @messages.map(&:position)
  end

  def test_session_metadata_and_title
    assert_equal "pi-stream-1",          @conv.session_id
    assert_equal "/tmp/pi-stream-project", @conv.original_cwd
    assert_equal "add a smoke test for the importer", @conv.title
  end

  def test_skips_non_message_end_events
    assert_equal 5, @messages.size,
      "expected 1 user + 1 assistant text + 1 assistant tool_use + 1 toolResult user + 1 terminal assistant = 5"
    assert_equal %w[user assistant assistant user assistant], @messages.map(&:role)
  end

  def test_epoch_ms_timestamps_converted_to_time
    user_msg = @messages.find { |m| m.role == "user" }
    refute_nil user_msg.occurred_at
    assert user_msg.occurred_at.year.between?(2024, 2030),
      "occurred_at year out of range: #{user_msg.occurred_at.year}"
  end

  def test_model_on_every_assistant_message
    assistants = @messages.select { |m| m.role == "assistant" }
    refute assistants.empty?
    assistants.each { |m| assert_equal "minimax/minimax-m3", m.model }
  end

  def test_synthesized_uuids_and_nil_parent_uuid
    expected = %w[pi-0 pi-1 pi-1-tools pi-2 pi-3]
    assert_equal expected, @messages.map(&:uuid)
    @messages.each { |m| assert_nil m.parent_uuid }
  end

  def test_thinking_normalized_to_text_and_tool_call_to_tool_use
    text_lead = @messages.find { |m| m.role == "assistant" && m.blocks.any? { |b| b["type"] == "text" } }
    tool_use  = @messages.find { |m| m.blocks.any? { |b| b["type"] == "tool_use" } }

    assert text_lead
    assert text_lead.blocks.any? { |b| b["type"] == "text" && b["text"] == "I'll write a smoke test for the importer next." }
    assert text_lead.blocks.any? { |b| b["type"] == "text" && b["text"] == "Let me check the existing test patterns." }

    assert tool_use
    assert_equal "read",                      tool_use.blocks.first["name"]
    assert_equal "call_stream_1",             tool_use.blocks.first["id"]
    assert_equal({ "file_path" => "/tmp/pi-stream-project/test/services/pi_importer_test.rb" }, tool_use.blocks.first["input"])
  end

  def test_tool_result_pairs_with_tool_use_id
    tool_uses    = @messages.select { |m| m.blocks.any? { |b| b["type"] == "tool_use" } }
    tool_results = @messages.select { |m| m.blocks.any? { |b| b["type"] == "tool_result" } }

    assert_equal 1, tool_uses.size
    assert_equal 1, tool_results.size
    assert_equal tool_uses.first.blocks.first["id"], tool_results.first.blocks.first["tool_use_id"]
    assert_equal "require \"test_helper\"", tool_results.first.blocks.first["content"]
    assert_equal false, tool_results.first.blocks.first["is_error"]
  end

  private

  def conversations_repo = Architect::Repos::ConversationsRepo.new
  def messages_repo      = Architect::Repos::MessagesRepo.new
  def fixture_path(name) = File.join(__dir__, "..", "fixtures", "files", name)
end

class PiImporterNulTest < Minitest::Test
  def conn
    @conn ||= Architect::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each do |t|
      conn[t].delete
    end
    @conv = Factory[:conversation]
    io = File.open(fixture_path("pi_streaming_with_nul.jsonl"))
    Architect::Importers::Pi.new.import!(@conv, io)
    io.close
    @conv     = conversations_repo.by_pk(@conv.id)
    @messages = messages_repo.for_conversation(@conv.id)
  end

  def test_completes_despite_nul_bytes
    assert_equal :completed, @conv.status
    assert_operator @messages.size, :>, 0
  end

  def test_strips_nul_from_all_persisted_content
    strings_inspected = 0
    @messages.each do |m|
      walk_strings(m.content) do |s|
        strings_inspected += 1
        refute_includes s, "\0", "Message uuid=#{m.uuid} block contains a U+0000 byte after scrub"
      end
    end
    assert_operator strings_inspected, :>, 0
  end

  def test_preserves_surrounding_text_when_nul_removed
    tool_result = @messages.find { |m| m.blocks.any? { |b| b["type"] == "tool_result" } }
    assert tool_result
    content = tool_result.blocks.first["content"]
    assert_includes content, "--wait"
    assert_includes content, "Waits for the process to exit."
    assert_includes content, "-k"
    assert_includes content, "Terminates the service if it is already running."
  end

  private

  def conversations_repo = Architect::Repos::ConversationsRepo.new
  def messages_repo      = Architect::Repos::MessagesRepo.new
  def fixture_path(name) = File.join(__dir__, "..", "fixtures", "files", name)

  def walk_strings(value, &block)
    case value
    when String then yield value
    when Array  then value.each { |v| walk_strings(v, &block) }
    when Hash   then value.each_value { |v| walk_strings(v, &block) }
    end
  end
end

class PiImporterErrorTest < Minitest::Test
  def conn
    @conn ||= Architect::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each do |t|
      conn[t].delete
    end
  end

  def test_raises_pi_import_error_on_zero_messages
    empty_lines = [
      { "type" => "session", "version" => 3, "id" => "empty", "timestamp" => "2026-06-13T09:00:00.000Z", "cwd" => "/tmp/empty" }.to_json,
      { "type" => "agent_start" }.to_json,
      { "type" => "turn_start" }.to_json
    ].join("\n")

    conv = Factory[:conversation]
    io   = StringIO.new(empty_lines)

    assert_raises(Architect::Importers::Pi::PiImportError) do
      Architect::Importers::Pi.new.import!(conv, io)
    end

    conv_after = conversations_repo.by_pk(conv.id)
    assert_equal :failed, conv_after.status
  end

  def test_fails_loud_on_tree_with_no_message_entries
    tree_only = { "type" => "session", "version" => 3, "id" => "empty-tree", "timestamp" => "2026-06-13T09:00:00.000Z", "cwd" => "/tmp/empty" }.to_json

    conv = Factory[:conversation]
    io   = StringIO.new(tree_only)

    assert_raises(Architect::Importers::Pi::PiImportError) do
      Architect::Importers::Pi.new.import!(conv, io)
    end

    conv_after = conversations_repo.by_pk(conv.id)
    assert_equal :failed, conv_after.status
  end

  private

  def conversations_repo = Architect::Repos::ConversationsRepo.new
  def messages_repo      = Architect::Repos::MessagesRepo.new
end
