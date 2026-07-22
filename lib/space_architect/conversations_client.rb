# frozen_string_literal: true

require "async/http/client"
require "async/http/endpoint"
require "json"
require "securerandom"

module Space::Architect
  # HTTP client for the space-server conversations upload API, modeled on
  # JobsClient: Bearer auth, injectable async-http client. Unlike JobsClient,
  # a non-2xx response is returned to the caller (not raised) — SessionSync
  # needs to distinguish created/updated/failed per file without aborting
  # the whole run on one bad upload.
  class ConversationsClient
    def initialize(host, token, client: nil, op_resolver: nil)
      @host = host.chomp("/")
      @token = token
      @client = client
      @op_resolver = op_resolver || SessionSync.method(:resolve_token)
      @resolved_token = nil
    end

    # POST /conversations — multipart per the frozen wire contract:
    # conversation[source_file] (the file), conversation[session_id].
    # Returns {status:, conversation_id:, action:, errors:}.
    def upload(path:, session_id:)
      Sync do
        with_client do |c|
          boundary = "ArchitectBoundary#{SecureRandom.hex(8)}"
          body = build_multipart(boundary, path, session_id)
          response = c.post("/conversations", headers: headers(boundary), body: body)
          status = response.status
          parsed = begin
            JSON.parse(response.read || "{}")
          rescue JSON::ParserError
            {}
          end
          {status: status, conversation_id: parsed["conversation_id"], action: parsed["action"], errors: parsed["errors"]}
        end
      end
    end

    private

    def with_client
      if @client
        yield @client
      else
        Async::HTTP::Client.open(Async::HTTP::Endpoint.parse(@host)) { |c| yield c }
      end
    end

    def headers(boundary)
      [
        ["authorization", "Bearer #{resolved_token}"],
        ["content-type", "multipart/form-data; boundary=#{boundary}"]
      ]
    end

    # Resolved once per client instance (per run), per spec.
    def resolved_token
      @resolved_token ||= @token.start_with?("op://") ? @op_resolver.call(@token) : @token
    end

    def build_multipart(boundary, path, session_id)
      crlf = "\r\n"
      filename = File.basename(path)
      file_content = File.binread(path)
      +"--#{boundary}#{crlf}" \
        "Content-Disposition: form-data; name=\"conversation[source_file]\"; filename=\"#{filename}\"#{crlf}" \
        "Content-Type: application/octet-stream#{crlf}" \
        "#{crlf}" \
        "#{file_content}#{crlf}" \
        "--#{boundary}#{crlf}" \
        "Content-Disposition: form-data; name=\"conversation[session_id]\"#{crlf}" \
        "#{crlf}" \
        "#{session_id}#{crlf}" \
        "--#{boundary}--#{crlf}"
    end
  end
end
