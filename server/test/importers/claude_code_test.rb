# frozen_string_literal: true

require_relative "../test_helper"

class ClaudeCodeImporterTest < Minitest::Test
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
    io = File.open(fixture_path("transcript.jsonl"))
    Architect::Importers::ClaudeCode.new.import!(@conv, io)
    io.close
    @conv     = conversations_repo.by_pk(@conv.id)
    @messages = messages_repo.for_conversation(@conv.id)
  end

  def test_imports_source_and_status
    assert_equal "claude_code", @conv.source
    assert_equal :completed, @conv.status
  end

  def test_imports_title_and_session_metadata
    assert_equal "Test conversation", @conv.title
    assert_equal "sess-1",   @conv.session_id
    assert_equal "/tmp/proj", @conv.original_cwd
    assert_equal "main",     @conv.git_branch
    assert_equal "2.1.0",    @conv.agent_version
  end

  def test_imports_three_messages_skipping_meta_and_bookkeeping
    assert_equal 3, @messages.size, "should skip ai-title, mode, snapshot, and meta records"
    assert_equal %w[user assistant user], @messages.map(&:role)
    assert_equal [0, 1, 2], @messages.map(&:position)
  end

  def test_second_message_model
    assert_equal "claude-opus-4-8", @messages[1].model
  end

  def test_normalizes_string_content_into_text_block
    assert_equal [{ "type" => "text", "text" => "Hello there" }], @messages[0].blocks
  end

  def test_preserves_structured_blocks_verbatim
    assistant = @messages[1]
    assert_equal %w[thinking text tool_use], assistant.blocks.map { |b| b["type"] }
    assert_equal "Bash", assistant.blocks.last["name"]
    assert_equal({ "command" => "ls" }, assistant.blocks.last["input"])
  end

  def test_third_message_is_tool_result
    # The third user message carries the tool_result content array, not a bare string.
    third = @messages[2]
    assert_equal "user", third.role
    assert_equal [{ "type" => "tool_result", "tool_use_id" => "t1", "content" => "file.txt", "is_error" => false }], third.blocks
  end

  private

  def conversations_repo = Architect::Repos::ConversationsRepo.new
  def messages_repo      = Architect::Repos::MessagesRepo.new
  def fixture_path(name) = File.join(__dir__, "..", "fixtures", "files", name)
end
