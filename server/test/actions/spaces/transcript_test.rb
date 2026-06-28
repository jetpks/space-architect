# frozen_string_literal: true

require_relative "../action_test_helper"

class SpacesTranscriptTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "transcript-owner-uid", username: "transcript-owner"]
    @other = Factory[:user, github_uid: "transcript-other-uid", username: "transcript-other"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # ── happy path — run with conversation ───────────────────────────────────────

  def test_transcript_returns_200_json
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    status, headers, _ = get("/spaces/#{space.id}/runs/#{run.id}/transcript")
    assert_equal 200, status
    assert_match "application/json", headers["content-type"]
  end

  def test_transcript_body_has_turns_key
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = get("/spaces/#{space.id}/runs/#{run.id}/transcript")
    data = parse_json(body)
    assert data.key?("turns"), "body must include turns key"
    assert_kind_of Array, data["turns"]
  end

  def test_transcript_turns_nonempty_for_run_with_conversation
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = get("/spaces/#{space.id}/runs/#{run.id}/transcript")
    turns = parse_json(body)["turns"]
    assert turns.length >= 1, "must return at least one turn"
  end

  def test_transcript_turns_shaped_like_turn_json
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = get("/spaces/#{space.id}/runs/#{run.id}/transcript")
    turn = parse_json(body)["turns"].first

    assert turn.key?("anchor_id"), "turn must include anchor_id"
    assert turn.key?("prompt"),    "turn must include prompt"
    assert turn.key?("rounds"),    "turn must include rounds"
  end

  def test_transcript_prompt_shaped_like_message_json
    sign_in(@owner)
    space, run = space_with_run_and_conversation
    _, _, body = get("/spaces/#{space.id}/runs/#{run.id}/transcript")
    prompt = parse_json(body)["turns"].first["prompt"]

    refute_nil prompt
    %w[id role position published blocks can_publish].each do |key|
      assert prompt.key?(key), "prompt must include '#{key}'"
    end
  end

  # ── no conversation ───────────────────────────────────────────────────────────

  def test_transcript_returns_empty_turns_when_no_conversation
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "no-conv-transcript-space"]
    run   = Factory[:run, user_id: @owner.id, space_id: space.id,
                    conversation_id: nil, role: "architect"]

    _, _, body = get("/spaces/#{space.id}/runs/#{run.id}/transcript")
    data = parse_json(body)
    assert_equal [], data["turns"]
  end

  # ── visibility / not-found guards ────────────────────────────────────────────

  def test_transcript_returns_404_for_missing_run
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "missing-run-transcript"]
    status, _, _ = get("/spaces/#{space.id}/runs/999999/transcript")
    assert_equal 404, status
  end

  def test_transcript_returns_404_when_run_belongs_to_different_space
    sign_in(@owner)
    space1 = Factory[:space, user_id: @owner.id, slug: "transcript-space-one"]
    space2 = Factory[:space, user_id: @owner.id, slug: "transcript-space-two"]
    run    = Factory[:run, user_id: @owner.id, space_id: space2.id, role: "architect"]

    status, _, _ = get("/spaces/#{space1.id}/runs/#{run.id}/transcript")
    assert_equal 404, status
  end

  def test_transcript_redirects_anon_on_private_space
    space = Factory[:space, user_id: @owner.id, slug: "private-transcript-space"]
    run   = Factory[:run, user_id: @owner.id, space_id: space.id,
                    conversation_id: nil, role: "architect"]

    status, headers, _ = get("/spaces/#{space.id}/runs/#{run.id}/transcript")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_transcript_redirects_when_run_not_visible_to_viewer
    sign_in(@owner)
    space = Factory[:space, user_id: @owner.id, slug: "vis-transcript-space"]
    run   = Factory[:run, user_id: @other.id, space_id: space.id,
                    published: false, role: "architect"]

    status, _, _ = get("/spaces/#{space.id}/runs/#{run.id}/transcript")
    assert_equal 302, status
  end

  private

  def space_with_run_and_conversation
    space = Factory[:space, user_id: @owner.id, slug: "transcript-conv-#{SecureRandom.hex(4)}"]
    conv  = Factory[:conversation, user_id: @owner.id]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "Hello from transcript" }],
            position: 1]
    run = Factory[:run, user_id: @owner.id, space_id: space.id,
                  conversation_id: conv.id, role: "architect"]
    [space, run]
  end
end
