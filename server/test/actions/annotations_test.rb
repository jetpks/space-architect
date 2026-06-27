# frozen_string_literal: true

require_relative "action_test_helper"

# L1-G1: annotations/{create,destroy} redirect + flash parity with oracle
# annotations_controller.rb:8-29.
class AnnotationsActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @owner    = Factory[:user, github_uid: "ann-owner-uid", username: "ann-owner"]
    @conv     = Factory[:conversation, user_id: @owner.id, published: true]
    @msg      = Factory[:message, conversation_id: @conv.id, role: "user",
                         content: [{"type" => "text", "text" => "q"}], position: 1, published: true]
    @ann_repo = Space::Server::App["repos.annotations_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def valid_ann_params
    { "annotation" => { "body" => "a note", "target_kind" => "conversation" } }
  end

  # ── annotations#create ──────────────────────────────────────────────────────

  def test_create_success_redirects_back
    sign_in(@owner)
    status, _, _ = post("/conversations/#{@conv.id}/annotations", params: valid_ann_params)
    assert_equal 302, status
  end

  def test_create_success_notice_annotation_added
    sign_in(@owner)
    _, headers, _ = post("/conversations/#{@conv.id}/annotations", params: valid_ann_params)
    flash = flash_from_redirect(headers)
    assert_equal "Annotation added.", flash["notice"]
  end

  def test_create_success_persists_annotation
    sign_in(@owner)
    post("/conversations/#{@conv.id}/annotations", params: valid_ann_params)
    assert_equal 1, @ann_repo.for_conversation(@conv.id).size
  end

  def test_create_contract_failure_redirects_back_with_alert
    sign_in(@owner)
    status, headers, _ = post(
      "/conversations/#{@conv.id}/annotations",
      params: { "annotation" => { "anchor_message_id" => "not_a_number" } }
    )
    assert_equal 302, status
    flash = flash_from_redirect(headers)
    refute_nil flash["alert"], "contract failure must produce an alert"
  end

  def test_create_contract_failure_does_not_persist
    sign_in(@owner)
    post(
      "/conversations/#{@conv.id}/annotations",
      params: { "annotation" => { "anchor_message_id" => "not_a_number" } }
    )
    assert_equal 0, @ann_repo.for_conversation(@conv.id).size
  end

  # ── annotations#destroy ─────────────────────────────────────────────────────

  def test_destroy_success_redirects_back
    sign_in(@owner)
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id]
    status, _, _ = delete("/annotations/#{ann.id}")
    assert_equal 302, status
  end

  def test_destroy_success_notice_annotation_removed
    sign_in(@owner)
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id]
    _, headers, _ = delete("/annotations/#{ann.id}")
    flash = flash_from_redirect(headers)
    assert_equal "Annotation removed.", flash["notice"]
  end

  def test_destroy_removes_annotation
    sign_in(@owner)
    ann = Factory[:annotation, conversation_id: @conv.id, user_id: @owner.id]
    delete("/annotations/#{ann.id}")
    assert_nil @ann_repo.by_pk(ann.id)
  end
end
