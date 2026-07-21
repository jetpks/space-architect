# frozen_string_literal: true

require_relative "action_test_helper"

# Session-sync (bearer) branch of POST /conversations: upsert-by-session_id,
# proving the I32 duplicate-on-re-upload defect is closed for session_id-bearing
# uploads. Browser-path regressions live in conversations_test.rb, unmodified.
class ConversationsSyncActionTest < Minitest::Test
  include ActionTestHelper

  TOKEN = "sync-secret-test-token-deadbeef0123456789"

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner    = Factory[:user, github_uid: "sync-owner-uid", username: "sync-owner"]
    @settings = Space::Server::App["settings"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def with_token_settings(token: TOKEN, user_id: nil)
    user_id ||= @owner.id
    @settings.stub(:ingest_token, token) do
      @settings.stub(:ingest_user_id, user_id) do
        yield
      end
    end
  end

  def fixture_path(name)
    File.join(__dir__, "..", "fixtures", "files", name)
  end

  def transcript_content
    @transcript_content ||= File.read(fixture_path("transcript.jsonl"))
  end

  def stub_import_queue
    processor = Space::Server::App["import_queue"]
    recorded_jobs = []
    processor.stub(:call, ->(job) { recorded_jobs << job }) { yield recorded_jobs }
  end

  def conversations_repo = Space::Server::Repos::ConversationsRepo.new

  def row_count
    Space::Server::App["db.gateway"].connection[:conversations].count
  end

  # --- AC1: bearer create ------------------------------------------------

  def test_bearer_create_persists_new_row_enqueues_and_returns_201
    with_token_settings do
      stub_import_queue do |recorded_jobs|
        status, headers, body = multipart_post("/conversations",
                                                content: transcript_content,
                                                filename: "transcript.jsonl",
                                                session_id: "sess-1",
                                                bearer: TOKEN)

        assert_equal 201, status
        assert_equal "application/json; charset=utf-8", headers["content-type"]
        data = parse_json(body)
        assert_equal "created", data["action"]
        refute_nil data["conversation_id"]

        assert_equal 1, row_count
        assert_equal 1, recorded_jobs.size
        assert_equal({ "conversation_id" => data["conversation_id"] }, recorded_jobs.first)

        conv = conversations_repo.by_pk(data["conversation_id"])
        assert_equal @owner.id, conv.user_id
        assert_equal "sess-1", conv.session_id
        refute_nil conv.source_file_data
      end
    end
  end

  # --- AC2: bearer upsert (second upload, same user+session_id) ---------

  def test_bearer_reupload_same_session_id_upserts_instead_of_duplicating
    with_token_settings do
      stub_import_queue do |recorded_jobs|
        status1, _, body1 = multipart_post("/conversations",
                                            content: transcript_content,
                                            filename: "transcript.jsonl",
                                            session_id: "sess-1",
                                            bearer: TOKEN)
        assert_equal 201, status1
        first_id = parse_json(body1)["conversation_id"]
        first_conv = conversations_repo.by_pk(first_id)

        replaced_content = transcript_content + "{\"type\":\"ai-title\",\"aiTitle\":\"Updated\",\"sessionId\":\"sess-1\"}\n"
        status2, headers2, body2 = multipart_post("/conversations",
                                                   content: replaced_content,
                                                   filename: "transcript.jsonl",
                                                   session_id: "sess-1",
                                                   bearer: TOKEN)

        assert_equal 200, status2
        data2 = parse_json(body2)
        assert_equal "updated", data2["action"]
        assert_equal first_id, data2["conversation_id"]

        assert_equal 1, row_count, "re-upload must reuse the row, not duplicate it"
        assert_equal 2, recorded_jobs.size, "import must be re-enqueued on update"
        assert_equal({ "conversation_id" => first_id }, recorded_jobs.last)

        updated_conv = conversations_repo.by_pk(first_id)
        assert_equal :pending, updated_conv.status, "status must be reset to pending on update"
        refute_equal first_conv.source_file_data, updated_conv.source_file_data,
          "source_file_data must be replaced by the new upload"
      end
    end
  end

  # --- AC1: bearer auth failures ------------------------------------------

  def test_bearer_empty_token_returns_401
    with_token_settings do
      status, _, body = multipart_post("/conversations",
                                        content: transcript_content,
                                        filename: "transcript.jsonl",
                                        session_id: "sess-1",
                                        bearer: "")
      assert_equal 401, status
      assert parse_json(body).key?("error")
      assert_equal 0, row_count
    end
  end

  def test_bearer_wrong_token_returns_401
    with_token_settings do
      status, _, _ = multipart_post("/conversations",
                                     content: transcript_content,
                                     filename: "transcript.jsonl",
                                     session_id: "sess-1",
                                     bearer: "wrong-token")
      assert_equal 401, status
      assert_equal 0, row_count
    end
  end

  def test_bearer_missing_session_id_returns_422
    with_token_settings do
      status, _, body = multipart_post("/conversations",
                                        content: transcript_content,
                                        filename: "transcript.jsonl",
                                        bearer: TOKEN)
      assert_equal 422, status
      errors = parse_json(body)["errors"]
      refute_empty errors
      assert_equal 0, row_count
    end
  end

  # --- AC3 (browser path): session_id-bearing browser upload upserts too --

  def test_browser_upload_with_session_id_upserts_on_reupload
    sign_in(@owner)
    stub_import_queue do |recorded_jobs|
      status1, headers1, = multipart_post("/conversations",
                                           content: transcript_content,
                                           filename: "transcript.jsonl",
                                           session_id: "sess-1")
      assert_equal 302, status1
      first_id = headers1["location"][/\d+/].to_i

      status2, headers2, = multipart_post("/conversations",
                                           content: transcript_content,
                                           filename: "transcript.jsonl",
                                           session_id: "sess-1")
      assert_equal 302, status2
      second_id = headers2["location"][/\d+/].to_i

      assert_equal first_id, second_id
      assert_equal 1, row_count
      assert_equal 2, recorded_jobs.size
    end
  end

  private

  def multipart_post(path, content:, filename:, session_id: nil, bearer: nil)
    boundary = "TestBoundary#{SecureRandom.hex(4)}"
    crlf = "\r\n"
    body = +""
    if session_id
      body << "--#{boundary}#{crlf}" \
               "Content-Disposition: form-data; name=\"conversation[session_id]\"#{crlf}" \
               "#{crlf}" \
               "#{session_id}#{crlf}"
    end
    body << "--#{boundary}#{crlf}" \
             "Content-Disposition: form-data; name=\"conversation[source_file]\"; filename=\"#{filename}\"#{crlf}" \
             "Content-Type: application/octet-stream#{crlf}" \
             "#{crlf}" \
             "#{content}#{crlf}" \
             "--#{boundary}--#{crlf}"

    env = Rack::MockRequest.env_for(
      path,
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
      input: body
    )
    env["HTTP_COOKIE"] = @session_cookie if @session_cookie
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" unless bearer.nil?
    app.call(env)
  end
end
