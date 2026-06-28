# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../app/contracts/create_conversation"

class CreateConversationContractTest < Minitest::Test
  def contract = Space::Server::Contracts::CreateConversation.new

  def test_valid_with_source_file
    r = contract.call(conversation: { source_file: "upload.jsonl" })
    assert r.success?
  end

  # source_file is now required (mirrors oracle `validates :source_file, presence: true`)
  def test_fails_when_source_file_missing
    r = contract.call(conversation: {})
    assert r.failure?
    assert_includes r.errors.to_h.dig(:conversation, :source_file), "is missing"
  end

  def test_unknown_key_is_dropped_not_rejected
    r = contract.call(conversation: { source_file: "f.jsonl", evil: "x" })
    assert r.success?
    refute r.to_h.dig(:conversation, :evil)
  end

  def test_rejects_conversation_as_string
    r = contract.call(conversation: "not_a_hash")
    assert r.failure?
    assert_includes r.errors.to_h[:conversation], "must be a hash"
  end

  def test_rejects_missing_outer_key
    r = contract.call({})
    assert r.failure?
    assert_includes r.errors.to_h[:conversation], "is missing"
  end

  def test_unknown_top_level_key_is_dropped
    r = contract.call(conversation: { source_file: "f.jsonl" }, extra: "x")
    assert r.success?
    refute r.to_h.key?(:extra)
  end
end
