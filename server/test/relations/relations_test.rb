# frozen_string_literal: true

require_relative "../test_helper"

# G1: Relations load, schema inferred, JSONB typed.
class RelationsTest < Minitest::Test
  TABLES = %i[users conversations messages annotations conversation_shares].freeze

  def rom
    @rom ||= Space::Server::App["db.rom"]
  end

  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    [:annotations, :conversation_shares, :messages, :conversations, :users].each do |t|
      conn[t].delete
    end
  end

  # --- G1: all 5 relations registered and queryable -------------------------

  def test_users_relation_queryable
    assert_kind_of Array, rom.relations[:users].to_a
  end

  def test_conversations_relation_queryable
    assert_kind_of Array, rom.relations[:conversations].to_a
  end

  def test_messages_relation_queryable
    assert_kind_of Array, rom.relations[:messages].to_a
  end

  def test_annotations_relation_queryable
    assert_kind_of Array, rom.relations[:annotations].to_a
  end

  def test_conversation_shares_relation_queryable
    assert_kind_of Array, rom.relations[:conversation_shares].to_a
  end

  # --- schema spot-checks ---------------------------------------------------

  def test_conversations_schema_includes_status_published_user_id
    attrs = rom.relations[:conversations].schema.map(&:name)
    assert_includes attrs, :status
    assert_includes attrs, :published
    assert_includes attrs, :user_id
  end

  def test_messages_schema_includes_content_position_conversation_id
    attrs = rom.relations[:messages].schema.map(&:name)
    assert_includes attrs, :content
    assert_includes attrs, :position
    assert_includes attrs, :conversation_id
  end

  # --- G1: JSONB predicate queries execute without error --------------------

  def test_users_github_orgs_jsonb_contain_executes
    assert_kind_of Array, rom.relations[:users].where { github_orgs.contain([]) }.to_a
  end

  def test_users_github_orgs_jsonb_has_key_executes
    assert_kind_of Array, rom.relations[:users].where { github_orgs.has_key("id") }.to_a
  end

  def test_messages_content_jsonb_contain_executes
    assert_kind_of Array, rom.relations[:messages].where { content.contain([]) }.to_a
  end

  def test_annotations_selector_jsonb_contain_executes
    assert_kind_of Array, rom.relations[:annotations].where { selector.contain({}) }.to_a
  end
end
