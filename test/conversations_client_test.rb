# frozen_string_literal: true

require_relative "test_helper"
require "async/http/mock"
require "async/http/client"
require "protocol/http/response"
require "json"
require "tmpdir"

class ConversationsClientTest < Space::ArchitectTest
  def mock_client
    mock_endpoint = Async::HTTP::Mock::Endpoint.new
    server_task = Async { mock_endpoint.run { |request| yield request } }
    client = Async::HTTP::Client.new(mock_endpoint)
    [client, server_task]
  end

  def with_session_file(content: "{}\n")
    Dir.mktmpdir("conversations-client-test") do |dir|
      path = File.join(dir, "20260101_abc-123.jsonl")
      File.write(path, content)
      yield path
    end
  end

  # (a) upload sends Bearer auth + a multipart body with both conversation[source_file]
  # (with the source filename + bytes) and conversation[session_id] fields, and returns
  # the parsed 201/"created" response.
  def test_upload_posts_multipart_with_bearer_auth_and_returns_created
    with_session_file(content: "hello world\n") do |path|
      Sync do
        client, server_task = mock_client do |request|
          assert_equal "POST",                request.method
          assert_equal "/conversations",      request.path
          assert_equal "Bearer secret-token", request.headers["authorization"]
          content_type = request.headers["content-type"]
          assert_match(%r{\Amultipart/form-data; boundary=}, content_type)
          boundary = content_type[/boundary=(\S+)/, 1]
          body = request.body.read

          assert_match(/name="conversation\[source_file\]"; filename="20260101_abc-123.jsonl"/, body)
          assert_match(/hello world/, body)
          assert_match(/name="conversation\[session_id\]"/, body)
          assert_match(/abc-123/, body)
          assert_includes body, "--#{boundary}--"

          Protocol::HTTP::Response[201, [["content-type", "application/json"]],
                                   [JSON.generate({conversation_id: 7, action: "created"})]]
        end

        result = Space::Architect::ConversationsClient.new("http://localhost", "secret-token", client: client)
          .upload(path: path, session_id: "abc-123")

        assert_equal 201,       result[:status]
        assert_equal 7,         result[:conversation_id]
        assert_equal "created", result[:action]

        client.close
        server_task.stop
      end
    end
  end

  # (b) A 200/"updated" response (existing (user_id, session_id) row reused) round-trips too.
  def test_upload_returns_updated_action_on_200
    with_session_file do |path|
      Sync do
        client, server_task = mock_client do |_request|
          Protocol::HTTP::Response[200, [["content-type", "application/json"]],
                                   [JSON.generate({conversation_id: 3, action: "updated"})]]
        end

        result = Space::Architect::ConversationsClient.new("http://localhost", "tok", client: client)
          .upload(path: path, session_id: "abc-123")

        assert_equal 200,       result[:status]
        assert_equal 3,         result[:conversation_id]
        assert_equal "updated", result[:action]

        client.close
        server_task.stop
      end
    end
  end

  # (c) A 422 (invalid params) is returned to the caller, not raised — the sync
  # runner needs to keep going and report a per-file failure.
  def test_upload_returns_422_errors_without_raising
    with_session_file do |path|
      Sync do
        client, server_task = mock_client do |_request|
          Protocol::HTTP::Response[422, [["content-type", "application/json"]],
                                   [JSON.generate({errors: ["session_id can't be blank"]})]]
        end

        result = Space::Architect::ConversationsClient.new("http://localhost", "tok", client: client)
          .upload(path: path, session_id: "abc-123")

        assert_equal 422, result[:status]
        assert_equal ["session_id can't be blank"], result[:errors]

        client.close
        server_task.stop
      end
    end
  end

  # (d) A 401 (bad/missing token) is likewise returned, not raised.
  def test_upload_returns_401_without_raising
    with_session_file do |path|
      Sync do
        client, server_task = mock_client do |_request|
          Protocol::HTTP::Response[401, [["content-type", "application/json"]],
                                   [JSON.generate({error: "Sign in required."})]]
        end

        result = Space::Architect::ConversationsClient.new("http://localhost", "bad-token", client: client)
          .upload(path: path, session_id: "abc-123")

        assert_equal 401, result[:status]

        client.close
        server_task.stop
      end
    end
  end

  # (e) an op:// token is resolved exactly once (per client instance) via the
  # injected resolver, and the RESOLVED value (not the ref) goes on the wire.
  def test_upload_resolves_op_token_once_via_injected_resolver
    with_session_file do |path|
      Sync do
        resolved_calls = []
        resolver = ->(ref) {
          resolved_calls << ref
          "resolved-secret"
        }

        client, server_task = mock_client do |request|
          assert_equal "Bearer resolved-secret", request.headers["authorization"]
          Protocol::HTTP::Response[201, [["content-type", "application/json"]],
                                   [JSON.generate({conversation_id: 1, action: "created"})]]
        end

        conv_client = Space::Architect::ConversationsClient.new(
          "http://localhost", "op://vault/item/field", client: client, op_resolver: resolver
        )
        conv_client.upload(path: path, session_id: "abc-123")
        conv_client.upload(path: path, session_id: "abc-123")

        assert_equal ["op://vault/item/field"], resolved_calls

        client.close
        server_task.stop
      end
    end
  end
end
