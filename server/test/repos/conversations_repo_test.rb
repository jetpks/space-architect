# frozen_string_literal: true

require_relative "../test_helper"

class ConversationsRepoTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    [:artifacts, :iterations, :annotations, :conversation_shares, :messages, :conversations, :jobs, :runs, :spaces, :users].each { |t| conn[t].delete }
  end

  def conversations_repo = Space::Server::Repos::ConversationsRepo.new
  def users_repo = Space::Server::Repos::UsersRepo.new

  # Reloaded through UsersRepo so callers get the auto_struct-mapped
  # Structs::User (with #org_ids) that visible_to's share lookup needs,
  # rather than the bare struct ROM::Factory hands back.
  def make_user(overrides = {})
    users_repo.by_pk(Factory[:user, **overrides].id)
  end

  # --- visible_to (I45 pagination) ----------------------------------------

  def test_visible_to_defaults_to_page_1_capped_at_page_size
    user = make_user
    55.times { Factory[:conversation, user_id: user.id, published: true] }
    result = conversations_repo.visible_to(user)
    assert_equal 50, result[:rows].length
    assert result[:has_more]
  end

  def test_visible_to_page_2_returns_remaining_rows_and_has_more_false
    user = make_user
    55.times { |i| Factory[:conversation, user_id: user.id, published: true, updated_at: Time.now - i] }
    result = conversations_repo.visible_to(user, page: 2)
    assert_equal 5, result[:rows].length
    refute result[:has_more]
  end

  def test_visible_to_orders_by_updated_at_desc
    user = make_user
    older = Factory[:conversation, user_id: user.id, published: true,
                     updated_at: Time.now - 3600, created_at: Time.now - 7200]
    newer = Factory[:conversation, user_id: user.id, published: true,
                     updated_at: Time.now, created_at: Time.now - 100]
    result = conversations_repo.visible_to(user)
    assert_equal [newer.id, older.id], result[:rows].map(&:id)
  end

  def test_visible_to_anonymous_sees_published_only
    user = make_user
    published = Factory[:conversation, user_id: user.id, published: true]
    Factory[:conversation, user_id: user.id, published: false]
    result = conversations_repo.visible_to(nil)
    assert_equal [published.id], result[:rows].map(&:id)
  end

  # Recording logger stand-in — Sequel::Database#loggers accepts anything
  # responding to the Logger interface; #info is what Sequel calls per query.
  class SqlSpy
    attr_reader :statements
    def initialize = @statements = []
    def info(msg) = @statements << msg
    def method_missing(*) = nil
    def respond_to_missing?(*) = true
  end

  # I36 discipline must hold under pagination too: visible_to combines :shares
  # only, never :messages, at any page.
  def test_visible_to_issues_no_message_queries_while_paging
    user = make_user
    55.times { |i| Factory[:conversation, user_id: user.id, published: true, updated_at: Time.now - i] }
    conv = Factory[:conversation, user_id: user.id, published: true]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "hi" }], position: 1]

    spy = SqlSpy.new
    conn.loggers << spy
    conversations_repo.visible_to(user, page: 2)
    conn.loggers.delete(spy)

    message_queries = spy.statements.select { |sql| sql.include?(%(FROM "messages")) }
    assert_equal 0, message_queries.length,
      "expected zero queries against messages, got #{message_queries.length}"
  end
end
