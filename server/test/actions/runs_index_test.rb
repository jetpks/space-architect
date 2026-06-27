# frozen_string_literal: true

require_relative "action_test_helper"

class RunsIndexTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "index-owner-uid", username: "index-owner"]
    @other = Factory[:user, github_uid: "index-other-uid", username: "index-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_index_returns_200_inertia_page
    status, headers, body = inertia_get("/runs")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    data = parse_json(body)
    assert_equal "Runs/Index", data["component"]
    assert_kind_of Array, data["props"]["runs"]
  end

  def test_index_returns_only_published_runs_for_anon
    Factory[:run, user_id: @owner.id, published: true]
    Factory[:run, user_id: @owner.id, published: false]
    _, _, body = inertia_get("/runs")
    data = parse_json(body)
    runs = data["props"]["runs"]
    assert_equal 1, runs.length
    assert runs.first["published"]
  end

  def test_index_returns_own_and_published_for_signed_in_user
    sign_in(@owner)
    own_private  = Factory[:run, user_id: @owner.id, published: false]
    own_public   = Factory[:run, user_id: @owner.id, published: true]
    other_public = Factory[:run, user_id: @other.id, published: true]
    Factory[:run, user_id: @other.id, published: false]  # must not appear

    _, _, body = inertia_get("/runs")
    data = parse_json(body)
    ids = data["props"]["runs"].map { |r| r["id"] }
    assert_includes ids, own_private.id,  "owner should see own private run"
    assert_includes ids, own_public.id,   "owner should see own public run"
    assert_includes ids, other_public.id, "owner should see other user's public run"
    assert_equal 3, ids.length
  end

  # FAITHFUL (AC-U3): this test MUST fail if list_visible_to returns all runs.
  # The foreign private run would appear, making the assertion fail.
  def test_index_does_not_return_other_users_private_run
    sign_in(@owner)
    foreign_private = Factory[:run, user_id: @other.id, published: false]
    own_private     = Factory[:run, user_id: @owner.id, published: false]

    _, _, body = inertia_get("/runs")
    data = parse_json(body)
    ids = data["props"]["runs"].map { |r| r["id"] }
    refute_includes ids, foreign_private.id, "must not expose another user's private run"
    assert_includes ids, own_private.id
    assert_equal 1, ids.length
  end

  def test_index_returns_runs_newest_first
    sign_in(@owner)
    old_run = Factory[:run, user_id: @owner.id, published: true, created_at: Time.now - 3600]
    new_run = Factory[:run, user_id: @owner.id, published: true, created_at: Time.now]

    _, _, body = inertia_get("/runs")
    data = parse_json(body)
    ids = data["props"]["runs"].map { |r| r["id"] }
    assert_equal new_run.id, ids.first, "newest run must appear first"
    assert_equal old_run.id, ids.last,  "oldest run must appear last"
  end

  def test_index_run_props_include_required_fields
    Factory[:run, user_id: @owner.id, status: 2, published: true]
    _, _, body = inertia_get("/runs")
    data = parse_json(body)
    run = data["props"]["runs"].first
    assert run.key?("id"),         "props.run must include id"
    assert run.key?("status"),     "props.run must include status"
    assert run.key?("published"),  "props.run must include published"
    assert run.key?("created_at"), "props.run must include created_at"
    assert_equal "complete", run["status"]
  end
end
