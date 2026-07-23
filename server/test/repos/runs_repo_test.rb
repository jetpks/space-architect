# frozen_string_literal: true

require_relative "../test_helper"

class RunsRepoTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    [:artifacts, :iterations, :annotations, :conversation_shares, :messages, :conversations, :jobs, :runs, :spaces, :users].each { |t| conn[t].delete }
  end

  def runs_repo = Space::Server::Repos::RunsRepo.new

  def make_user(overrides = {})
    Factory[:user, **overrides]
  end

  # --- list_visible_to (I45 pagination) -----------------------------------

  def test_list_visible_to_defaults_to_page_1_capped_at_page_size
    user = make_user
    55.times { Factory[:run, user_id: user.id, published: true] }
    result = runs_repo.list_visible_to(user)
    assert_equal 50, result[:rows].length
    assert result[:has_more]
  end

  def test_list_visible_to_page_2_returns_remaining_rows_and_has_more_false
    user = make_user
    55.times { |i| Factory[:run, user_id: user.id, published: true, created_at: Time.now - i] }
    result = runs_repo.list_visible_to(user, page: 2)
    assert_equal 5, result[:rows].length
    refute result[:has_more]
  end

  def test_list_visible_to_orders_newest_first
    user = make_user
    older = Factory[:run, user_id: user.id, published: true, created_at: Time.now - 60]
    newer = Factory[:run, user_id: user.id, published: true]
    result = runs_repo.list_visible_to(user)
    assert_equal [newer.id, older.id], result[:rows].map(&:id)
  end

  def test_list_visible_to_anonymous_sees_published_only
    user = make_user
    published = Factory[:run, user_id: user.id, published: true]
    Factory[:run, user_id: user.id, published: false]
    result = runs_repo.list_visible_to(nil)
    assert_equal [published.id], result[:rows].map(&:id)
  end

  def test_list_visible_to_signed_in_sees_own_private_and_published
    user  = make_user
    other = make_user
    own_private  = Factory[:run, user_id: user.id, published: false]
    other_public = Factory[:run, user_id: other.id, published: true]
    Factory[:run, user_id: other.id, published: false]

    result = runs_repo.list_visible_to(user)
    ids = result[:rows].map(&:id)
    assert_includes ids, own_private.id
    assert_includes ids, other_public.id
    assert_equal 2, ids.length
  end
end
