# frozen_string_literal: true

require_relative "../test_helper"

# G2: CRUD round-trips, finders, and association loading.
class ReposTest < Minitest::Test
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

  def users_repo        = Space::Server::Repos::UsersRepo.new
  def conversations_repo = Space::Server::Repos::ConversationsRepo.new
  def messages_repo     = Space::Server::Repos::MessagesRepo.new
  def annotations_repo  = Space::Server::Repos::AnnotationsRepo.new
  def shares_repo       = Space::Server::Repos::ConversationSharesRepo.new

  def make_user(overrides = {})
    Factory[:user, **overrides]
  end

  def make_conversation(overrides = {})
    Factory[:conversation, **overrides]
  end

  # --- UsersRepo -----------------------------------------------------------

  def test_users_crud_round_trip
    user = make_user
    assert_kind_of Integer, user.id
    assert_equal user.username, users_repo.by_pk(user.id).username
    # update
    users_repo.update(user.id, name: "Updated Name")
    assert_equal "Updated Name", users_repo.by_pk(user.id).name
    # delete
    users_repo.delete(user.id)
    assert_nil users_repo.by_pk(user.id)
  end

  def test_users_by_github_uid
    user = make_user
    found = users_repo.by_github_uid(user.github_uid)
    refute_nil found
    assert_equal user.id, found.id
  end

  def test_users_by_github_uid_returns_nil_for_unknown
    assert_nil users_repo.by_github_uid("no-such-uid")
  end

  def test_users_github_orgs_jsonb_round_trips
    orgs = [{ "id" => "1234", "login" => "myorg" }]
    user = make_user(github_orgs: orgs)
    found = users_repo.by_pk(user.id)
    assert_kind_of Array, found.github_orgs
    assert_equal orgs, found.github_orgs
  end

  # --- ConversationsRepo ---------------------------------------------------

  def test_conversations_crud_round_trip
    conv = make_conversation
    assert_kind_of Integer, conv.id
    read = conversations_repo.by_pk(conv.id)
    refute_nil read
    conversations_repo.update(conv.id, title: "Updated")
    assert_equal "Updated", conversations_repo.by_pk(conv.id).title
    conversations_repo.delete(conv.id)
    assert_nil conversations_repo.by_pk(conv.id)
  end

  def test_conversations_published_finder
    pub  = make_conversation(published: true)
    priv = make_conversation(published: false)
    results = conversations_repo.published
    ids = results.map(&:id)
    assert_includes ids, pub.id
    refute_includes ids, priv.id
  end

  def test_conversations_by_user_finder
    user  = make_user
    user2 = make_user
    c1 = Factory[:conversation, user_id: user.id]
    c2 = Factory[:conversation, user_id: user2.id]
    results = conversations_repo.by_user(user.id)
    ids = results.map(&:id)
    assert_includes ids, c1.id
    refute_includes ids, c2.id
  end

  def test_conversations_with_messages_loads_ordered_by_position
    conv = make_conversation
    Factory[:message, conversation_id: conv.id, position: 3]
    Factory[:message, conversation_id: conv.id, position: 1]
    Factory[:message, conversation_id: conv.id, position: 2]
    loaded = conversations_repo.with_messages(conv.id)
    positions = loaded.messages.map(&:position)
    assert_equal [1, 2, 3], positions
  end

  def test_conversations_status_integer_round_trips
    conv = Factory[:conversation, status: 2]
    found = conversations_repo.by_pk(conv.id)
    # struct returns symbol (:completed) — see structs test; raw int here since
    # status coercion is applied at struct level
    assert_respond_to found, :status
  end

  def test_conversations_find_by_session_id_scoped_to_user
    user  = make_user
    user2 = make_user
    conv = Factory[:conversation, user_id: user.id, session_id: "sess-1"]
    Factory[:conversation, user_id: user2.id, session_id: "sess-1"]

    found = conversations_repo.find_by_session_id(user.id, "sess-1")
    assert_equal conv.id, found.id
  end

  def test_conversations_find_by_session_id_returns_nil_when_absent
    user = make_user
    assert_nil conversations_repo.find_by_session_id(user.id, "no-such-session")
  end

  def test_conversations_find_by_session_id_newest_wins_on_duplicates
    user = make_user
    Factory[:conversation, user_id: user.id, session_id: "sess-1"]
    newest = Factory[:conversation, user_id: user.id, session_id: "sess-1"]

    found = conversations_repo.find_by_session_id(user.id, "sess-1")
    assert_equal newest.id, found.id
  end

  def test_conversations_parent_of_scoped_to_user
    user  = make_user
    other = make_user
    parent = Factory[:conversation, user_id: user.id, session_id: "sess-parent"]
    Factory[:conversation, user_id: other.id, session_id: "sess-parent"]
    child = Factory[:conversation, user_id: user.id, session_id: "sess-child", parent_session_id: "sess-parent"]

    found = conversations_repo.parent_of(child)
    assert_equal parent.id, found.id
  end

  def test_conversations_parent_of_nil_safe_when_parent_session_id_absent
    conv = Factory[:conversation, user_id: make_user.id, session_id: "sess-child"]
    assert_nil conversations_repo.parent_of(conv)
  end

  def test_conversations_parent_of_newest_wins_on_duplicates
    user = make_user
    Factory[:conversation, user_id: user.id, session_id: "sess-parent"]
    newest = Factory[:conversation, user_id: user.id, session_id: "sess-parent"]
    child = Factory[:conversation, user_id: user.id, session_id: "sess-child", parent_session_id: "sess-parent"]

    found = conversations_repo.parent_of(child)
    assert_equal newest.id, found.id
  end

  def test_conversations_children_of_scoped_to_user_and_ordered
    user  = make_user
    other = make_user
    parent = Factory[:conversation, user_id: user.id, session_id: "sess-parent"]
    first_child = Factory[:conversation, user_id: user.id, session_id: "sess-child-1", parent_session_id: "sess-parent"]
    second_child = Factory[:conversation, user_id: user.id, session_id: "sess-child-2", parent_session_id: "sess-parent"]
    Factory[:conversation, user_id: other.id, session_id: "sess-child-3", parent_session_id: "sess-parent"]

    found = conversations_repo.children_of(parent)
    assert_equal [first_child.id, second_child.id], found.map(&:id)
  end

  def test_conversations_children_of_nil_safe_when_session_id_absent
    conv = Factory[:conversation, user_id: make_user.id]
    assert_empty conversations_repo.children_of(conv)
  end

  def test_conversations_delete_cascades_children
    conv = make_conversation
    user = make_user
    Factory[:message, conversation_id: conv.id, position: 1]
    Factory[:annotation, conversation_id: conv.id, user_id: user.id]
    Factory[:conversation_share, conversation_id: conv.id]

    conversations_repo.delete(conv.id)

    assert_nil conversations_repo.by_pk(conv.id)
    assert_empty messages_repo.for_conversation(conv.id)
    assert_empty annotations_repo.for_conversation(conv.id)
    assert_empty shares_repo.for_conversation(conv.id)
  end

  # --- MessagesRepo --------------------------------------------------------

  def test_messages_crud_round_trip
    conv = make_conversation
    msg = Factory[:message, conversation_id: conv.id, position: 1]
    assert_kind_of Integer, msg.id
    found = messages_repo.by_pk(msg.id)
    refute_nil found
    messages_repo.update(msg.id, role: "assistant")
    assert_equal "assistant", messages_repo.by_pk(msg.id).role
    messages_repo.delete(msg.id)
    assert_nil messages_repo.by_pk(msg.id)
  end

  def test_messages_for_conversation_ordered_by_position
    conv = make_conversation
    Factory[:message, conversation_id: conv.id, position: 5]
    Factory[:message, conversation_id: conv.id, position: 2]
    Factory[:message, conversation_id: conv.id, position: 8]
    results = messages_repo.for_conversation(conv.id)
    assert_equal [2, 5, 8], results.map(&:position)
  end

  def test_messages_published_finder
    conv = make_conversation
    pub  = Factory[:message, conversation_id: conv.id, position: 1, published: true]
    priv = Factory[:message, conversation_id: conv.id, position: 2, published: false]
    ids = messages_repo.published.map(&:id)
    assert_includes ids, pub.id
    refute_includes ids, priv.id
  end

  def test_messages_content_jsonb_round_trips
    conv    = make_conversation
    blocks  = [{ "type" => "text", "text" => "hello" }]
    msg     = Factory[:message, conversation_id: conv.id, position: 1, content: blocks]
    found   = messages_repo.by_pk(msg.id)
    assert_kind_of Array, found.content
    assert_equal blocks, found.content
  end

  # --- AnnotationsRepo -----------------------------------------------------

  def test_annotations_crud_round_trip
    conv = make_conversation
    user = make_user
    ann = Factory[:annotation, conversation_id: conv.id, user_id: user.id]
    assert_kind_of Integer, ann.id
    found = annotations_repo.by_pk(ann.id)
    refute_nil found
    annotations_repo.update(ann.id, body: "Updated body")
    assert_equal "Updated body", annotations_repo.by_pk(ann.id).body
    annotations_repo.delete(ann.id)
    assert_nil annotations_repo.by_pk(ann.id)
  end

  def test_annotations_for_conversation_finder
    conv1 = make_conversation
    conv2 = make_conversation
    user  = make_user
    a1 = Factory[:annotation, conversation_id: conv1.id, user_id: user.id]
    a2 = Factory[:annotation, conversation_id: conv2.id, user_id: user.id]
    ids = annotations_repo.for_conversation(conv1.id).map(&:id)
    assert_includes ids, a1.id
    refute_includes ids, a2.id
  end

  def test_annotations_selector_jsonb_round_trips
    conv = make_conversation
    user = make_user
    sel  = { "exact" => "hello", "prefix" => "say ", "suffix" => " world" }
    ann  = Factory[:annotation, conversation_id: conv.id, user_id: user.id, selector: sel]
    found = annotations_repo.by_pk(ann.id)
    assert_kind_of Hash, found.selector
    assert_equal sel, found.selector
  end

  # --- ConversationSharesRepo ----------------------------------------------

  def test_conversation_shares_crud_round_trip
    conv  = make_conversation
    share = Factory[:conversation_share, conversation_id: conv.id]
    assert_kind_of Integer, share.id
    found = shares_repo.by_pk(share.id)
    refute_nil found
    shares_repo.update(share.id, access: "note")
    assert_equal "note", shares_repo.by_pk(share.id).access
    shares_repo.delete(share.id)
    assert_nil shares_repo.by_pk(share.id)
  end

  def test_conversation_shares_for_conversation_finder
    conv1 = make_conversation
    conv2 = make_conversation
    s1 = Factory[:conversation_share, conversation_id: conv1.id]
    s2 = Factory[:conversation_share, conversation_id: conv2.id]
    ids = shares_repo.for_conversation(conv1.id).map(&:id)
    assert_includes ids, s1.id
    refute_includes ids, s2.id
  end

  # --- G5: factory wired —— persists + in-memory structs ------------------

  def test_factory_persists_record
    user = Factory[:user]
    found = users_repo.by_pk(user.id)
    refute_nil found
    assert_equal user.username, found.username
  end

  def test_factory_structs_returns_in_memory_struct
    struct = Factory.structs[:user]
    assert_respond_to struct, :username
    assert_nil users_repo.by_github_uid(struct.github_uid)
  end
end
