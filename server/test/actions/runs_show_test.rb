# frozen_string_literal: true

require_relative "action_test_helper"

class RunsShowTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "show-owner-uid", username: "show-owner"]
    @other = Factory[:user, github_uid: "show-other-uid", username: "show-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def test_show_returns_200_for_published_run_anon
    run = Factory[:run, user_id: @owner.id, status: 2, published: true]
    status, headers, body = inertia_get("/runs/#{run.id}")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    data = parse_json(body)
    assert_equal "Runs/Show", data["component"]
    assert_equal run.id, data["props"]["run"]["id"]
  end

  def test_show_props_include_status_and_published
    run = Factory[:run, user_id: @owner.id, status: 2, published: true]
    _, _, body = inertia_get("/runs/#{run.id}")
    data = parse_json(body)
    assert data["props"]["run"].key?("status"),    "props.run must include status"
    assert data["props"]["run"].key?("published"), "props.run must include published"
    assert_equal true, data["props"]["run"]["published"]
  end

  def test_show_redirects_302_for_anon_on_private_run
    run = Factory[:run, user_id: @owner.id, status: 0, published: false]
    status, headers, _ = get("/runs/#{run.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_returns_200_for_owner_on_private_run
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 0, published: false]
    status, _, body = inertia_get("/runs/#{run.id}")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal "Runs/Show", data["component"]
    assert_equal run.id, data["props"]["run"]["id"]
  end

  def test_show_redirects_other_user_on_private_run
    sign_in(@other)
    run = Factory[:run, user_id: @owner.id, status: 0, published: false]
    status, headers, _ = get("/runs/#{run.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_returns_404_for_missing_run
    status, _, _ = inertia_get("/runs/99999")
    assert_equal 404, status
  end

  def test_show_props_include_run_metadata
    run = Factory[:run, user_id: @owner.id, status: 2, published: true,
                  harness: "claude", model: "qwen3-27b-optiq", producer: "claude_code"]
    _, _, body = inertia_get("/runs/#{run.id}")
    props = parse_json(body)["props"]["run"]
    assert_equal "claude",          props["harness"]
    assert_equal "qwen3-27b-optiq", props["model"]
    assert_equal "builder",         props["role"]
    assert_equal "claude_code",     props["producer"]
    assert props.key?("created_at")
    assert props.key?("updated_at")
  end

  def test_show_includes_job_for_owner
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 2, published: true]
    job = Factory[:job, user_id: @owner.id, status: "succeeded", run_id: run.id]
    _, _, body = inertia_get("/runs/#{run.id}")
    props = parse_json(body)["props"]["run"]
    assert_equal job.id,         props["job"]["id"]
    assert_equal "succeeded",    props["job"]["status"]
    assert_equal "do the thing", props["job"]["prompt"]
  end

  def test_show_omits_job_for_anon_and_non_owner
    run = Factory[:run, user_id: @owner.id, status: 2, published: true]
    Factory[:job, user_id: @owner.id, status: "succeeded", run_id: run.id]

    _, _, body = inertia_get("/runs/#{run.id}")
    assert_nil parse_json(body)["props"]["run"]["job"]

    sign_in(@other)
    _, _, body = inertia_get("/runs/#{run.id}")
    assert_nil parse_json(body)["props"]["run"]["job"]
  end
end
