# frozen_string_literal: true

require_relative "../action_test_helper"

class SpacesRunTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "spaces-run-owner-uid", username: "spaces-run-owner"]
    @other = Factory[:user, github_uid: "spaces-run-other-uid", username: "spaces-run-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── happy path ───────────────────────────────────────────────────────────────

  def test_run_renders_spaces_run_component
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    status, _, body = inertia_get("/spaces/#{space.id}/runs/#{run.id}")
    assert_equal 200, status
    assert_equal "Spaces/Run", parse_json(body)["component"]
  end

  def test_run_props_include_space_run_turns
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = inertia_get("/spaces/#{space.id}/runs/#{run.id}")
    props = parse_json(body)["props"]

    assert props.key?("space"), "must include space"
    assert props.key?("run"),   "must include run"
    assert props.key?("turns"), "must include turns"
  end

  def test_run_space_props_shape
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = inertia_get("/spaces/#{space.id}/runs/#{run.id}")
    space_data = parse_json(body)["props"]["space"]

    assert_equal space.id,   space_data["id"]
    assert_equal space.slug, space_data["slug"]
    assert space_data.key?("title")
  end

  def test_run_props_run_shape
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body  = inertia_get("/spaces/#{space.id}/runs/#{run.id}")
    run_data    = parse_json(body)["props"]["run"]

    %w[id lane role status producer session_id iteration_id conversation_id].each do |key|
      assert run_data.key?(key), "run props must include '#{key}'"
    end
    assert_equal run.id, run_data["id"]
  end

  def test_run_returns_at_least_one_turn_for_run_with_conversation
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = inertia_get("/spaces/#{space.id}/runs/#{run.id}")
    turns = parse_json(body)["props"]["turns"]

    assert_kind_of Array, turns
    assert turns.length >= 1, "must return at least one turn"
  end

  def test_run_turns_shaped_like_turn_json
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = inertia_get("/spaces/#{space.id}/runs/#{run.id}")
    turn = parse_json(body)["props"]["turns"].first

    assert turn.key?("anchor_id"), "turn must include anchor_id"
    assert turn.key?("prompt"),    "turn must include prompt"
    assert turn.key?("rounds"),    "turn must include rounds"
  end

  def test_run_prompt_shaped_like_message_json
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = inertia_get("/spaces/#{space.id}/runs/#{run.id}")
    prompt = parse_json(body)["props"]["turns"].first["prompt"]

    refute_nil prompt, "first turn must have a prompt"
    %w[id role position published blocks can_publish].each do |key|
      assert prompt.key?(key), "prompt must include '#{key}'"
    end
  end

  # ── no conversation ───────────────────────────────────────────────────────────

  def test_run_returns_empty_turns_when_no_conversation
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "no-conv-space"]
    run   = Factory[:run, user_id: @owner.id, space_id: space.id,
                    conversation_id: nil, role: "builder"]

    _, _, body = inertia_get("/spaces/#{space.id}/runs/#{run.id}")
    props = parse_json(body)["props"]

    assert_equal 200, 200  # doesn't crash
    assert_equal [], props["turns"]
  end

  # ── visibility guards ─────────────────────────────────────────────────────────

  def test_run_returns_404_for_missing_run
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "missing-run-space"]
    status, _, _ = inertia_get("/spaces/#{space.id}/runs/999999")
    assert_equal 404, status
  end

  def test_run_returns_404_when_run_belongs_to_different_space
    sign_in(@owner)
    space1 = Factory[:space, user_id: @owner.id, slug: "run-space-one"]
    space2 = Factory[:space, user_id: @owner.id, slug: "run-space-two"]
    run    = Factory[:run, user_id: @owner.id, space_id: space2.id, role: "builder"]

    status, _, _ = inertia_get("/spaces/#{space1.id}/runs/#{run.id}")
    assert_equal 404, status
  end

  def test_run_redirects_anon_on_private_space
    space = Factory[:space, user_id: @owner.id, slug: "private-run-space"]
    run   = Factory[:run, user_id: @owner.id, space_id: space.id,
                    conversation_id: nil, role: "builder"]

    status, headers, _ = get("/spaces/#{space.id}/runs/#{run.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_run_redirects_when_run_not_visible_to_viewer
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "vis-run-space"]
    # run owned by @other, not published → not visible to @owner
    run = Factory[:run, user_id: @other.id, space_id: space.id,
                  published: false, role: "builder"]

    status, _, _ = get("/spaces/#{space.id}/runs/#{run.id}")
    assert_equal 302, status
  end

  private

  def space_with_run_and_conversation
    space = Factory[:space, user_id: @owner.id, slug: "run-conv-#{SecureRandom.hex(4)}"]
    conv  = Factory[:conversation, user_id: @owner.id]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "Hello from run transcript" }],
            position: 1]
    run = Factory[:run, user_id: @owner.id, space_id: space.id,
                  conversation_id: conv.id, role: "builder", lane: "lane-a"]
    [space, run]
  end
end
