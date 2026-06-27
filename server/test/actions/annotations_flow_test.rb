# frozen_string_literal: true

require_relative "action_test_helper"

# Integration-flow parity for test/integration/annotations_flow_test.rb.
# Covers annotation creation across all 5 target kinds, selector storage,
# incoherent target rejection, and snippet viewer annotation filtering.
class AnnotationsFlowTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @owner = Factory[:user, github_uid: "flow-ann-owner", username: "flow-ann-owner"]
    # Keep conversation unpublished so visible_messages scoping is tested;
    # owner can annotate regardless of published flag (owned_by? check).
    @conv  = Factory[:conversation, user_id: @owner.id, published: false]

    # Three messages spanning all annotation target kinds:
    #   @prompt    — turn anchor and prompt anchor (user/text)
    #   @assistant — round anchor and tool anchor (assistant/tool_use with id "t1")
    #   @result    — machinery (user/tool_result-only) — in @assistant's round
    @prompt = Factory[:message, conversation_id: @conv.id, role: "user",
                      content: [{"type" => "text", "text" => "q"}],
                      position: 1, published: false]
    @assistant = Factory[:message, conversation_id: @conv.id, role: "assistant",
                         content: [{"type" => "tool_use", "id" => "t1", "name" => "bash", "input" => {}}],
                         position: 2, published: false]
    @result = Factory[:message, conversation_id: @conv.id, role: "user",
                      content: [{"type" => "tool_result", "tool_use_id" => "t1", "content" => "ok"}],
                      position: 3, published: false]
    @ann_repo = Architect::App["repos.annotations_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def create_annotation(attrs)
    post(
      "/conversations/#{@conv.id}/annotations",
      params: {"annotation" => {"body" => "a note", **attrs.transform_keys(&:to_s)}}
    )
  end

  # Mirror of oracle: "annotations attach at every level of the hierarchy"
  def test_annotations_attach_at_every_level_of_hierarchy
    sign_in(@owner)
    before = @ann_repo.for_conversation(@conv.id).size

    create_annotation(target_kind: "conversation")
    create_annotation(target_kind: "turn",    anchor_message_id: @prompt.id)
    create_annotation(target_kind: "round",   anchor_message_id: @assistant.id)
    create_annotation(target_kind: "tool",    anchor_message_id: @assistant.id, tool_use_id: "t1")
    create_annotation(target_kind: "message", anchor_message_id: @result.id)

    assert_equal before + 5, @ann_repo.for_conversation(@conv.id).size,
      "each of the 5 annotation kinds must be persisted"
  end

  # Mirror of oracle: "a range annotation stores its selector"
  def test_range_annotation_stores_selector
    sign_in(@owner)
    post(
      "/conversations/#{@conv.id}/annotations",
      params: {"annotation" => {
        "body" => "selected passage",
        "target_kind" => "message",
        "anchor_message_id" => @prompt.id.to_s,
        "selector" => {"exact" => "q", "prefix" => "", "suffix" => ""}
      }}
    )
    ann = @ann_repo.for_conversation(@conv.id).last
    refute_nil ann, "annotation must be persisted"
    assert_equal "q", ann.selector&.dig("exact"), "selector.exact must be stored"
    assert_equal "",  ann.selector&.dig("prefix"), "selector.prefix must be stored"
  end

  # Mirror of oracle: "an incoherent target persists nothing and reports why"
  # @result is machinery (tool_result-only), so it is not a round anchor.
  # Submitting target_kind:"round" with @result.id is incoherent.
  def test_incoherent_target_persists_nothing_and_reports_why
    sign_in(@owner)
    before = @ann_repo.for_conversation(@conv.id).size

    _, headers, _ = create_annotation(target_kind: "round", anchor_message_id: @result.id)

    assert_equal before, @ann_repo.for_conversation(@conv.id).size,
      "incoherent target must not be persisted"
    flash = flash_from_redirect(headers)
    assert_equal "target not found in this conversation", flash["alert"]
  end

  # Mirror of oracle: "snippet viewers only receive annotations on anchors they can see"
  # Unpublished conversation with one published message → stranger is a snippet viewer.
  # Annotation on the unpublished @prompt is hidden; annotation on published @assistant shows.
  def test_snippet_viewers_only_receive_annotations_on_visible_anchors
    msg_repo = Architect::App["repos.messages_repo"]
    # Publish @assistant so the conversation is accessible to snippet viewers
    # (visible_to? requires at least one published message when conv is unpublished).
    msg_repo.update(@assistant.id, published: true, updated_at: Time.now)

    sign_in(@owner)
    create_annotation(target_kind: "conversation")
    create_annotation(target_kind: "message", anchor_message_id: @assistant.id)
    create_annotation(target_kind: "message", anchor_message_id: @prompt.id)

    viewer = Factory[:user, github_uid: "flow-snippet-viewer", username: "flow-snippet-viewer"]
    sign_in(viewer)

    _, _, body = inertia_get("/conversations/#{@conv.id}")
    data  = parse_json(body)
    pairs = data["props"]["annotations"].map { |a| [a["target_kind"], a["anchor_message_id"]] }

    assert_includes pairs, ["conversation", nil],         "conversation-target annotation must appear"
    assert_includes pairs, ["message", @assistant.id],    "annotation on published message must appear"
    refute_includes pairs, ["message", @prompt.id],       "annotation on unpublished message must not appear"
  end
end
