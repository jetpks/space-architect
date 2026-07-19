# frozen_string_literal: true

require "async/http/client"
require "async/http/endpoint"
require "json"

module Space::Architect
  # HTTP client for the space-server jobs API, modeled on RunCreator: Bearer
  # auth, injectable async-http client, Space::Core::Error on any failure.
  class JobsClient
    # Poll bound for #wait_for_run_id: 2s * 30 attempts = 60s. Both are
    # injectable kwargs so tests need not sleep real seconds.
    POLL_INTERVAL_SECONDS = 2
    POLL_MAX_ATTEMPTS     = 30

    def initialize(host, token, client: nil)
      @host   = host.chomp("/")
      @token  = token
      @client = client
    end

    # GET /jobs — returns the "jobs" array (owner-scoped, newest-first).
    def list
      get_json("/jobs")["jobs"]
    end

    # GET /jobs/:id — returns the job JSON.
    def show(id)
      get_json("/jobs/#{id}")
    end

    # POST /jobs/:id/cancel — returns {"id"=>.., "status"=>"canceled"}.
    def cancel(id)
      Sync do
        with_client do |c|
          response = c.post("/jobs/#{id}/cancel", headers: headers, body: nil)
          parse_json(response, "POST /jobs/#{id}/cancel")
        end
      end
    end

    # GET /runs/:id/stream — yields each SSE event's data: payload to the
    # block as it arrives. Returns when the stream reports run_complete or
    # closes cleanly. Raises Space::Core::Error on a non-200 response.
    def stream(run_id, &block)
      Sync do
        with_client do |c|
          response = c.get("/runs/#{run_id}/stream", headers: headers)
          unless response.status == 200
            body = response.read || ""
            raise Space::Core::Error, "GET /runs/#{run_id}/stream failed (#{response.status}): #{body[0, 200]}"
          end

          read_sse(response, &block)
        end
      end
    end

    # Polls GET /jobs/:id until run_id is present, waiting `interval` seconds
    # between attempts, up to `attempts` tries. Raises Space::Core::Error if
    # the bound is exceeded.
    def wait_for_run_id(id, interval: POLL_INTERVAL_SECONDS, attempts: POLL_MAX_ATTEMPTS)
      attempts.times do |i|
        run_id = show(id)["run_id"]
        return run_id if run_id
        sleep interval unless i == attempts - 1
      end
      raise Space::Core::Error, "job #{id}: no run_id after #{attempts} attempts (#{attempts * interval}s)"
    end

    private

    def get_json(path)
      Sync do
        with_client do |c|
          response = c.get(path, headers: headers)
          parse_json(response, "GET #{path}")
        end
      end
    end

    def with_client
      if @client
        yield @client
      else
        Async::HTTP::Client.open(Async::HTTP::Endpoint.parse(@host)) { |c| yield c }
      end
    end

    def headers
      [
        ["authorization", "Bearer #{@token}"],
        ["content-type",  "application/json"]
      ]
    end

    def parse_json(response, what)
      status = response.status
      body   = response.read || ""
      raise Space::Core::Error, "#{what} failed (#{status}): #{body[0, 200]}" unless status == 200

      JSON.parse(body)
    end

    # Buffers chunks and splits on the SSE event terminator ("\n\n"). Each
    # event's data: line(s) are joined and yielded; an event whose data JSON
    # carries type == "run_complete" ends the stream.
    def read_sse(response)
      buffer = +""
      response.each do |chunk|
        buffer << chunk
        while (boundary = buffer.index("\n\n"))
          event = buffer.slice!(0..boundary + 1)
          data  = event.each_line.select { |line| line.start_with?("data:") }
                        .map { |line| line.sub(/\Adata:\s?/, "").chomp }
                        .join("\n")
          next if data.empty?

          yield data
          parsed = begin
            JSON.parse(data)
          rescue JSON::ParserError
            nil
          end
          return if parsed.is_a?(Hash) && parsed["type"] == "run_complete"
        end
      end
    end
  end
end
