# frozen_string_literal: true

require_relative "action_test_helper"

# L1-G1: messages/publish redirect + flash parity with oracle messages_controller.rb:6-14.
class MessagesActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true

    @owner    = Factory[:user, github_uid: "msg-owner-uid", username: "msg-owner"]
    @conv     = Factory[:conversation, user_id: @owner.id, published: false]
    @msg      = Factory[:message, conversation_id: @conv.id, role: "user",
                         content: [{"type" => "text", "text" => "q"}], position: 1, published: false]
    @msg_repo = Architect::App["repos.messages_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # Toggling unpublished → published: notice says "published"
  def test_publish_unpublished_redirects_to_conversation_with_anchor
    sign_in(@owner)
    status, headers, _ = patch("/messages/#{@msg.id}/publish")
    assert_equal 302, status
    assert_equal "/conversations/#{@conv.id}#message-#{@msg.id}", headers["location"]
  end

  def test_publish_unpublished_notice_says_published
    sign_in(@owner)
    _, headers, _ = patch("/messages/#{@msg.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Turn published.", flash["notice"]
  end

  # Toggling published → unpublished: notice says "unpublished"
  def test_publish_published_notice_says_unpublished
    @msg_repo.update(@msg.id, published: true, updated_at: Time.now)
    sign_in(@owner)
    _, headers, _ = patch("/messages/#{@msg.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Turn unpublished.", flash["notice"]
  end

  def test_publish_toggles_published_state
    sign_in(@owner)
    patch("/messages/#{@msg.id}/publish")
    updated = @msg_repo.by_pk(@msg.id)
    assert_equal true, updated.published
  end
end
