# frozen_string_literal: true

require_relative "../test_helper"

# G3: Struct enum coercion, JSONB read-through, blocks interface.
class StructsTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each do |t|
      conn[t].delete
    end
  end

  def conversations_repo = Space::Server::Repos::ConversationsRepo.new
  def messages_repo      = Space::Server::Repos::MessagesRepo.new
  def users_repo         = Space::Server::Repos::UsersRepo.new
  def annotations_repo   = Space::Server::Repos::AnnotationsRepo.new

  # --- Conversation: status enum coercion (all 4 values) ------------------

  def test_status_0_pending
    c = Factory[:conversation, status: 0]
    assert_equal :pending, conversations_repo.by_pk(c.id).status
  end

  def test_status_1_processing
    c = Factory[:conversation, status: 1]
    assert_equal :processing, conversations_repo.by_pk(c.id).status
  end

  def test_status_2_completed
    c = Factory[:conversation, status: 2]
    assert_equal :completed, conversations_repo.by_pk(c.id).status
  end

  def test_status_3_failed
    c = Factory[:conversation, status: 3]
    assert_equal :failed, conversations_repo.by_pk(c.id).status
  end

  def test_conversation_struct_class
    c    = Factory[:conversation]
    read = conversations_repo.by_pk(c.id)
    assert_kind_of Space::Server::Structs::Conversation, read
  end

  # --- Message: blocks == Array(content) -----------------------------------

  def test_message_blocks_returns_array_of_content
    conv   = Factory[:conversation]
    blocks = [{ "type" => "text", "text" => "hi" }, { "type" => "thinking", "thinking" => "hm" }]
    msg    = Factory[:message, conversation_id: conv.id, position: 1, content: blocks]
    found  = messages_repo.by_pk(msg.id)
    assert_kind_of Array, found.content
    assert_equal found.content, found.blocks
    assert_equal blocks, found.blocks
  end

  def test_message_blocks_empty_content
    conv  = Factory[:conversation]
    msg   = Factory[:message, conversation_id: conv.id, position: 1, content: []]
    found = messages_repo.by_pk(msg.id)
    assert_equal [], found.blocks
  end

  def test_message_struct_class
    conv  = Factory[:conversation]
    msg   = Factory[:message, conversation_id: conv.id, position: 1]
    found = messages_repo.by_pk(msg.id)
    assert_kind_of Space::Server::Structs::Message, found
  end

  # --- User: github_orgs JSONB surfaces as Ruby Array ---------------------

  def test_user_github_orgs_array
    user  = Factory[:user, github_orgs: [{ "id" => "99", "login" => "org" }]]
    found = users_repo.by_pk(user.id)
    assert_kind_of Array, found.github_orgs
    assert_equal "99", found.github_orgs.first["id"]
  end

  def test_user_struct_class
    user  = Factory[:user]
    found = users_repo.by_pk(user.id)
    assert_kind_of Space::Server::Structs::User, found
  end

  # --- Annotation: selector JSONB surfaces as Ruby Hash -------------------

  def test_annotation_selector_hash
    conv = Factory[:conversation]
    user = Factory[:user]
    sel  = { "exact" => "text", "position" => 5 }
    ann  = Factory[:annotation, conversation_id: conv.id, user_id: user.id, selector: sel]
    found = annotations_repo.by_pk(ann.id)
    assert_kind_of Hash, found.selector
    assert_equal "text", found.selector["exact"]
  end

  def test_annotation_selector_nil_when_not_set
    conv = Factory[:conversation]
    user = Factory[:user]
    ann  = Factory[:annotation, conversation_id: conv.id, user_id: user.id]
    found = annotations_repo.by_pk(ann.id)
    assert_nil found.selector
  end

  def test_annotation_struct_class
    conv = Factory[:conversation]
    user = Factory[:user]
    ann  = Factory[:annotation, conversation_id: conv.id, user_id: user.id]
    found = annotations_repo.by_pk(ann.id)
    assert_kind_of Space::Server::Structs::Annotation, found
  end
end
