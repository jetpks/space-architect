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

  def test_index_run_props_include_identity_fields
    Factory[:run, user_id: @owner.id, published: true, harness: "claude", model: "sonnet", lane: "builder-a"]
    _, _, body = inertia_get("/runs")
    run = parse_json(body)["props"]["runs"].first
    assert_equal "claude",     run["harness"]
    assert_equal "sonnet",     run["model"]
    assert_equal "builder-a",  run["lane"]
  end

  def test_index_prompt_snippet_present_for_owner_with_job
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, published: false]
    Factory[:job, user_id: @owner.id, run_id: run.id, spec: { "harness" => { "type" => "claude" }, "prompt" => "do the thing" }]

    _, _, body = inertia_get("/runs")
    entry = parse_json(body)["props"]["runs"].find { |r| r["id"] == run.id }
    assert_equal "do the thing", entry["prompt_snippet"]
  end

  def test_index_prompt_snippet_truncated_and_single_line
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, published: false]
    long_prompt = "line one\nline two #{"x" * 150}"
    Factory[:job, user_id: @owner.id, run_id: run.id, spec: { "harness" => { "type" => "claude" }, "prompt" => long_prompt }]

    _, _, body = inertia_get("/runs")
    entry = parse_json(body)["props"]["runs"].find { |r| r["id"] == run.id }
    refute_includes entry["prompt_snippet"], "\n"
    assert_equal 141, entry["prompt_snippet"].length
    assert entry["prompt_snippet"].end_with?("…")
  end

  def test_index_prompt_snippet_nil_for_non_owner
    run = Factory[:run, user_id: @owner.id, published: true]
    Factory[:job, user_id: @owner.id, run_id: run.id, spec: { "harness" => { "type" => "claude" }, "prompt" => "secret plan" }]

    sign_in(@other)
    _, _, body = inertia_get("/runs")
    entry = parse_json(body)["props"]["runs"].find { |r| r["id"] == run.id }
    assert_nil entry["prompt_snippet"]
  end

  def test_index_prompt_snippet_nil_for_anon
    run = Factory[:run, user_id: @owner.id, published: true]
    Factory[:job, user_id: @owner.id, run_id: run.id, spec: { "harness" => { "type" => "claude" }, "prompt" => "secret plan" }]

    _, _, body = inertia_get("/runs")
    entry = parse_json(body)["props"]["runs"].find { |r| r["id"] == run.id }
    assert_nil entry["prompt_snippet"]
  end

  def test_index_prompt_snippet_nil_when_no_job
    Factory[:run, user_id: @owner.id, published: true]
    sign_in(@owner)
    _, _, body = inertia_get("/runs")
    entry = parse_json(body)["props"]["runs"].first
    assert_nil entry["prompt_snippet"]
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

  def test_index_resolves_jobs_with_a_single_bulk_query
    sign_in(@owner)
    3.times do
      run = Factory[:run, user_id: @owner.id, published: false]
      Factory[:job, user_id: @owner.id, run_id: run.id]
    end

    connection = Space::Server::App["db.gateway"].connection
    spy = SqlSpy.new
    connection.loggers << spy
    inertia_get("/runs")
    connection.loggers.delete(spy)

    job_queries = spy.statements.select { |sql| sql.include?(%(FROM "jobs")) }
    assert_equal 1, job_queries.length, "expected exactly one query against jobs (bulk by_run_ids), got #{job_queries.length}"
  end
end
