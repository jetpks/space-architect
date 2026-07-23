# frozen_string_literal: true

require_relative "../test_helper"

class RunStructTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :runs, :users].each { |t| conn[t].delete }

    @repo       = Space::Server::App["repos.runs_repo"]
    @users_repo = Space::Server::App["repos.users_repo"]

    @owner   = @users_repo.by_pk(Factory[:user, github_uid: "1", username: "owner"].id)
    @stranger = @users_repo.by_pk(Factory[:user, github_uid: "2", username: "stranger"].id)
  end

  def make_run(status:, published: false)
    @repo.by_pk(Factory[:run, user_id: @owner.id, status: status, published: published].id)
  end

  # Status predicates

  def test_pending_status_predicate
    run = make_run(status: 0)
    assert run.pending?,   "status 0 must be pending?"
    refute run.live?,      "status 0 must not be live?"
    refute run.complete?,  "status 0 must not be complete?"
    refute run.failed?,    "status 0 must not be failed?"
    refute run.canceled?,  "status 0 must not be canceled?"
  end

  def test_live_status_predicate
    run = make_run(status: 1)
    refute run.pending?,   "status 1 must not be pending?"
    assert run.live?,      "status 1 must be live?"
    refute run.complete?,  "status 1 must not be complete?"
    refute run.failed?,    "status 1 must not be failed?"
    refute run.canceled?,  "status 1 must not be canceled?"
  end

  def test_complete_status_predicate
    run = make_run(status: 2)
    refute run.pending?,   "status 2 must not be pending?"
    refute run.live?,      "status 2 must not be live?"
    assert run.complete?,  "status 2 must be complete?"
    refute run.failed?,    "status 2 must not be failed?"
    refute run.canceled?,  "status 2 must not be canceled?"
  end

  def test_failed_status_predicate
    run = make_run(status: 3)
    refute run.pending?,   "status 3 must not be pending?"
    refute run.live?,      "status 3 must not be live?"
    refute run.complete?,  "status 3 must not be complete?"
    assert run.failed?,    "status 3 must be failed?"
    refute run.canceled?,  "status 3 must not be canceled?"
  end

  def test_canceled_status_predicate
    run = make_run(status: 4)
    refute run.pending?,   "status 4 must not be pending?"
    refute run.live?,      "status 4 must not be live?"
    refute run.complete?,  "status 4 must not be complete?"
    refute run.failed?,    "status 4 must not be failed?"
    assert run.canceled?,  "status 4 must be canceled?"
  end

  # Auth predicates — private run

  def test_owned_by_and_visible_to_for_private_run
    run = make_run(status: 0, published: false)
    assert run.owned_by?(@owner),     "owner must own private run"
    refute run.owned_by?(@stranger),  "stranger must not own private run"
    refute run.owned_by?(nil),        "nil must not own any run"

    assert run.visible_to?(@owner),   "owner must see private run"
    refute run.visible_to?(@stranger), "stranger must not see private run"
    refute run.visible_to?(nil),       "anon must not see private run"
  end

  # Auth predicates — published run

  def test_visible_to_for_published_run
    run = make_run(status: 2, published: true)
    assert run.published?,             "published flag must be true"
    assert run.visible_to?(nil),       "anon must see published run"
    assert run.visible_to?(@stranger), "stranger must see published run"
    assert run.visible_to?(@owner),    "owner must see published run"
  end
end
