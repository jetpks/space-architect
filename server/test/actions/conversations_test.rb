# frozen_string_literal: true

require_relative "action_test_helper"

# Basic contract tests for conversations index/show/create and sessions.
# All render paths use inertia_get (X-Inertia) for hermetic, manifest-free tests.
class ConversationsActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner = Factory[:user, github_uid: "test-owner-uid", username: "owner"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def fixture_path(name)
    File.join(__dir__, "..", "fixtures", "files", name)
  end

  # Build a multipart/form-data request body for a single file field.
  def multipart_post(path, file_path, filename)
    boundary = "TestBoundary#{SecureRandom.hex(4)}"
    file_content = File.binread(file_path)
    crlf = "\r\n"
    body = "--#{boundary}#{crlf}" \
           "Content-Disposition: form-data; name=\"conversation[source_file]\"; filename=\"#{filename}\"#{crlf}" \
           "Content-Type: application/octet-stream#{crlf}" \
           "#{crlf}" \
           "#{file_content}#{crlf}" \
           "--#{boundary}--#{crlf}"

    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
      input: body
    )
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    app.call(env)
  end

  # --- conversations.index (GET /) ---

  def test_index_returns_200_inertia_page
    status, headers, body = inertia_get("/")
    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]
    assert_equal "true", headers["x-inertia"]
    data = parse_json(body)
    assert_equal "Conversations/Index", data["component"]
    assert_kind_of Array, data["props"]["conversations"]
  end

  def test_index_returns_only_published_conversations_for_anon
    Factory[:conversation, published: true]
    Factory[:conversation, published: false]
    _, _, body = inertia_get("/")
    data = parse_json(body)
    conversations = data["props"]["conversations"]
    assert_equal 1, conversations.length
    assert conversations.first["published"]
  end

  def test_conversations_path_returns_index_component
    status1, _, body1 = inertia_get("/")
    status2, _, body2 = inertia_get("/conversations")
    assert_equal 200, status1
    assert_equal 200, status2
    assert_equal "Conversations/Index", parse_json(body1)["component"]
    assert_equal "Conversations/Index", parse_json(body2)["component"]
  end

  # --- conversations.show (GET /conversations/:id) ---

  def test_show_returns_200_for_published_conv_anon
    conv = Factory[:conversation, published: true]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "hello" }], position: 1]

    status, headers, body = inertia_get("/conversations/#{conv.id}")
    assert_equal 200, status
    assert_equal "true", headers["x-inertia"]
    data = parse_json(body)
    assert_equal "Conversations/Show", data["component"]
    assert_equal conv.id, data["props"]["conversation"]["id"]
    assert data["props"].key?("turns"), "props must include turns"
    assert data["props"].key?("annotations"), "props must include annotations"
  end

  def test_show_redirects_302_for_anon_on_private_conv
    conv = Factory[:conversation, published: false, user_id: @owner.id]
    status, headers, _ = get("/conversations/#{conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
  end

  def test_show_returns_200_for_owner_on_private_conv
    sign_in(@owner)
    conv = Factory[:conversation, published: false, user_id: @owner.id]
    Factory[:message, conversation_id: conv.id, role: "user",
            content: [{ "type" => "text", "text" => "hello" }], position: 1]

    status, _, body = inertia_get("/conversations/#{conv.id}")
    assert_equal 200, status
    data = parse_json(body)
    assert_equal conv.id, data["props"]["conversation"]["id"]
    assert data["props"].key?("turns")
  end

  def test_show_includes_can_note_and_can_manage_in_props
    sign_in(@owner)
    conv = Factory[:conversation, published: false, user_id: @owner.id]
    _, _, body = inertia_get("/conversations/#{conv.id}")
    data = parse_json(body)
    assert data["props"]["conversation"].key?("can_note"),   "props.conversation must include can_note"
    assert data["props"]["conversation"].key?("can_manage"), "props.conversation must include can_manage"
    assert_equal true, data["props"]["conversation"]["can_note"]
    assert_equal true, data["props"]["conversation"]["can_manage"]
  end

  def test_show_returns_404_for_missing_conversation
    status, _, _ = inertia_get("/conversations/99999")
    assert_equal 404, status
  end

  def test_show_data_includes_turns
    conv = Factory[:conversation, published: true]
    Factory[:message, conversation_id: conv.id, role: "assistant",
            content: [{ "type" => "text", "text" => "hi" }], position: 1]

    _, _, body = inertia_get("/conversations/#{conv.id}")
    data = parse_json(body)
    assert data["props"]["turns"].is_a?(Array)
  end

  # --- Error mapping: 404 ---

  def test_conversations_show_404_for_nonexistent_id
    status, headers, body = inertia_get("/conversations/0")
    assert_equal 404, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)
    assert data.key?("error")
  end

  # --- conversations.create ---

  def test_create_redirects_anon_with_flash
    status, headers, _ = post("/conversations", params: { "conversation" => { "source_file" => "x.jsonl" } })
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Please sign in to continue.", flash["alert"]
  end

  def test_create_redirects_to_new_with_errors_for_invalid_params
    sign_in(@owner)
    status, headers, _ = post("/conversations", params: { "conversation" => "not_a_hash" })
    assert_equal 302, status
    assert_equal "/conversations/new", headers["location"]
    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/conversations/new", cookie: redirect_cookie)
    data = parse_json(body)
    refute_empty data.dig("props", "errors"), "props.errors must be non-empty after contract failure"
  end

  # G4: missing source_file → flat error, no row persisted
  # Send an empty string for source_file (encodes as conversation[source_file]=)
  # so the outer conversation key IS present but source_file fails .filled check.
  def test_create_missing_source_file_returns_flat_error
    sign_in(@owner)
    status, headers, _ = post("/conversations", params: { "conversation" => { "source_file" => "" } })
    assert_equal 302, status
    assert_equal "/conversations/new", headers["location"]

    redirect_cookie = headers["set-cookie"]&.split(";")&.first
    _, _, body = inertia_get("/conversations/new", cookie: redirect_cookie)
    data = parse_json(body)
    errors = data.dig("props", "errors")
    refute_empty errors
    assert errors.key?("source_file"), "errors must have top-level source_file key (flat shape), got: #{errors.inspect}"

    # No row persisted
    assert_equal 0, Architect::App["db.gateway"].connection[:conversations].count,
      "No conversation must be persisted on missing source_file"
  end

  # G4: valid multipart POST → persists conversation, enqueues job, redirects with flash
  # The action is frozen (Hanami singleton), so we stub the processor object in the
  # container (same reference as action's @import_queue) rather than the action instance.
  def test_create_success_persists_enqueues_and_redirects
    sign_in(@owner)

    # Ensure the provider is started so we can get a reference to the processor
    processor = Architect::App["import_queue"]
    recorded_jobs = []

    # Stub the processor's call method — same object the action holds in @import_queue
    processor.stub(:call, ->(job) { recorded_jobs << job }) do
      status, headers, _ = multipart_post("/conversations",
                                          fixture_path("transcript.jsonl"),
                                          "transcript.jsonl")

      assert_equal 302, status, "Expected redirect after successful create"
      assert_match %r{/conversations/\d+}, headers["location"], "Expected redirect to /conversations/:id"

      flash = flash_from_redirect(headers)
      assert_equal "Uploaded — importing now.", flash["notice"]

      # Job was enqueued with the new conversation id
      assert_equal 1, recorded_jobs.size
      conv_id = headers["location"][/\d+/].to_i
      assert_equal({ "conversation_id" => conv_id }, recorded_jobs.first)

      # Conversation persisted with correct user_id, source_file_data, pending status
      conv = Architect::Repos::ConversationsRepo.new.by_pk(conv_id)
      refute_nil conv, "Conversation must be persisted"
      assert_equal @owner.id, conv.user_id
      refute_nil conv.source_file_data, "source_file_data must be present"
      assert_equal :pending, conv.status, "status must be pending"
    end
  end

  # --- conversations.publish + conversations.destroy flash parity (L1-G1) ---

  def test_publish_unpublished_notice_says_published
    conv = Factory[:conversation, user_id: @owner.id, published: false]
    sign_in(@owner)
    _, headers, _ = patch("/conversations/#{conv.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Conversation published.", flash["notice"]
  end

  def test_publish_published_notice_says_unpublished
    conv = Factory[:conversation, user_id: @owner.id, published: true]
    sign_in(@owner)
    _, headers, _ = patch("/conversations/#{conv.id}/publish")
    flash = flash_from_redirect(headers)
    assert_equal "Conversation unpublished.", flash["notice"]
  end

  def test_publish_redirects_to_conversation
    conv = Factory[:conversation, user_id: @owner.id, published: false]
    sign_in(@owner)
    status, headers, _ = patch("/conversations/#{conv.id}/publish")
    assert_equal 302, status
    assert_equal "/conversations/#{conv.id}", headers["location"]
  end

  def test_destroy_redirects_to_root_with_notice
    conv = Factory[:conversation, user_id: @owner.id, published: false]
    sign_in(@owner)
    status, headers, _ = delete("/conversations/#{conv.id}")
    assert_equal 302, status
    assert_equal "/", headers["location"]
    flash = flash_from_redirect(headers)
    assert_equal "Conversation deleted.", flash["notice"]
  end

  # --- sessions seams ---

  def test_auth_callback_redirects
    status, _, _ = get("/auth/github/callback")
    assert_equal 302, status
  end

  def test_logout_get_redirects
    status, _, _ = get("/logout")
    assert_equal 302, status
  end
end
