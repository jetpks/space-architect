# frozen_string_literal: true

require_relative "test_helper"
require "async/http/mock"
require "async/http/client"
require "protocol/http/response"
require "json"

class JobsClientTest < Space::ArchitectTest
  def mock_client
    mock_endpoint = Async::HTTP::Mock::Endpoint.new
    server_task = Async { mock_endpoint.run { |request| yield request } }
    client = Async::HTTP::Client.new(mock_endpoint)
    [client, server_task]
  end

  # (a) GET /jobs with Bearer auth returns the "jobs" array.
  def test_list_gets_jobs_with_auth_and_returns_array
    Sync do
      client, server_task = mock_client do |request|
        assert_equal "GET",                 request.method
        assert_equal "/jobs",               request.path
        assert_equal "Bearer secret-token", request.headers["authorization"]
        Protocol::HTTP::Response[200, [["content-type", "application/json"]],
                                 [JSON.generate({ jobs: [{ id: 1, status: "pending", run_id: nil, created_at: "2026-01-01T00:00:00Z" }] })]]
      end

      jobs = Space::Architect::JobsClient.new("http://localhost", "secret-token", client: client).list

      assert_equal 1, jobs.length
      assert_equal 1, jobs.first["id"]

      client.close
      server_task.stop
    end
  end

  # (b) GET /jobs/:id returns the job JSON directly (not wrapped).
  def test_show_gets_job_by_id
    Sync do
      client, server_task = mock_client do |request|
        assert_equal "GET",       request.method
        assert_equal "/jobs/42",  request.path
        Protocol::HTTP::Response[200, [["content-type", "application/json"]],
                                 [JSON.generate({ id: 42, status: "running", run_id: 7 })]]
      end

      job = Space::Architect::JobsClient.new("http://localhost", "tok", client: client).show(42)

      assert_equal 42, job["id"]
      assert_equal 7,  job["run_id"]

      client.close
      server_task.stop
    end
  end

  # (c) show raises Space::Core::Error on non-200 (401/403/404 per contract).
  def test_show_raises_on_non_200
    Sync do
      client, server_task = mock_client do |_request|
        Protocol::HTTP::Response[404, [["content-type", "application/json"]],
                                 [JSON.generate({ error: "not found" })]]
      end

      creator = Space::Architect::JobsClient.new("http://localhost", "tok", client: client)
      assert_raises(Space::Core::Error) { creator.show(99) }

      client.close
      server_task.stop
    end
  end

  # (d) POST /jobs/:id/cancel with Bearer auth returns the server response.
  def test_cancel_posts_to_cancel_endpoint
    Sync do
      client, server_task = mock_client do |request|
        assert_equal "POST",                request.method
        assert_equal "/jobs/5/cancel",      request.path
        assert_equal "Bearer secret-token", request.headers["authorization"]
        request.body&.read
        Protocol::HTTP::Response[200, [["content-type", "application/json"]],
                                 [JSON.generate({ id: 5, status: "canceled" })]]
      end

      result = Space::Architect::JobsClient.new("http://localhost", "secret-token", client: client).cancel(5)

      assert_equal 5,          result["id"]
      assert_equal "canceled", result["status"]

      client.close
      server_task.stop
    end
  end

  # (e) cancel raises Space::Core::Error on 409 (already terminal, per contract).
  def test_cancel_raises_on_409
    Sync do
      client, server_task = mock_client do |_request|
        Protocol::HTTP::Response[409, [["content-type", "application/json"]],
                                 [JSON.generate({ error: "already terminal" })]]
      end

      creator = Space::Architect::JobsClient.new("http://localhost", "tok", client: client)
      assert_raises(Space::Core::Error) { creator.cancel(5) }

      client.close
      server_task.stop
    end
  end

  # (f) stream reads Bearer-authed SSE, yields each event's data: payload,
  # and stops after the run_complete event.
  def test_stream_yields_data_payloads_and_stops_at_run_complete
    Sync do
      client, server_task = mock_client do |request|
        assert_equal "GET",                 request.method
        assert_equal "/runs/9/stream",      request.path
        assert_equal "Bearer secret-token", request.headers["authorization"]
        body = [
          "data: #{JSON.generate(type: "message_start")}\n\n",
          "data: #{JSON.generate(type: "run_complete")}\n\n"
        ]
        Protocol::HTTP::Response[200, [["content-type", "text/event-stream"]], body]
      end

      received = []
      Space::Architect::JobsClient.new("http://localhost", "secret-token", client: client)
        .stream(9) { |data| received << data }

      assert_equal 2, received.length
      assert_equal "message_start", JSON.parse(received[0])["type"]
      assert_equal "run_complete",  JSON.parse(received[1])["type"]

      client.close
      server_task.stop
    end
  end

  # (g) stream raises Space::Core::Error on a non-200 response (auth errors).
  def test_stream_raises_on_non_200
    Sync do
      client, server_task = mock_client do |_request|
        Protocol::HTTP::Response[401, [["content-type", "application/json"]],
                                 [JSON.generate({ error: "Sign in required." })]]
      end

      creator = Space::Architect::JobsClient.new("http://localhost", "tok", client: client)
      assert_raises(Space::Core::Error) { creator.stream(9) { |_data| } }

      client.close
      server_task.stop
    end
  end

  # (h) stream ends cleanly (no exception, no run_complete) on a plain closed
  # body — the "clean close" exit path.
  def test_stream_ends_cleanly_without_run_complete_event
    Sync do
      client, server_task = mock_client do |_request|
        Protocol::HTTP::Response[200, [["content-type", "text/event-stream"]],
                                 ["data: #{JSON.generate(type: "message_start")}\n\n"]]
      end

      received = []
      Space::Architect::JobsClient.new("http://localhost", "tok", client: client)
        .stream(9) { |data| received << data }

      assert_equal 1, received.length

      client.close
      server_task.stop
    end
  end

  # (i-a) POST /jobs with Bearer auth + a JSON body returns the created job's id.
  def test_create_posts_job_spec_with_auth_and_returns_id
    Sync do
      spec = { "prompt" => "do the thing", "harness" => { "type" => "claude" } }
      client, server_task = mock_client do |request|
        assert_equal "POST",                request.method
        assert_equal "/jobs",               request.path
        assert_equal "Bearer secret-token", request.headers["authorization"]
        body = JSON.parse(request.body.read)
        assert_equal spec, body
        Protocol::HTTP::Response[201, [["content-type", "application/json"]],
                                 [JSON.generate({ id: 7, status: "pending" })]]
      end

      id = Space::Architect::JobsClient.new("http://localhost", "secret-token", client: client).create(spec)

      assert_equal 7, id

      client.close
      server_task.stop
    end
  end

  # (i-b) Non-201 response raises Space::Core::Error.
  def test_create_raises_on_non_201_response
    Sync do
      client, server_task = mock_client do |_request|
        Protocol::HTTP::Response[422, [["content-type", "application/json"]],
                                 [JSON.generate({ error: "invalid mount(s)" })]]
      end

      creator = Space::Architect::JobsClient.new("http://localhost", "tok", client: client)
      assert_raises(Space::Core::Error) { creator.create({}) }

      client.close
      server_task.stop
    end
  end

  # (i-c) 201 with a missing/non-integer id raises Space::Core::Error.
  def test_create_raises_on_non_integer_id_in_201_body
    Sync do
      client, server_task = mock_client do |_request|
        Protocol::HTTP::Response[201, [["content-type", "application/json"]],
                                 [JSON.generate({ id: "not-an-int" })]]
      end

      creator = Space::Architect::JobsClient.new("http://localhost", "tok", client: client)
      assert_raises(Space::Core::Error) { creator.create({}) }

      client.close
      server_task.stop
    end
  end

  # (j) wait_for_run_id polls show until run_id is present, using the
  # injected (near-zero) interval so the test doesn't sleep real seconds.
  def test_wait_for_run_id_polls_until_present
    Sync do
      call_count = 0
      client, server_task = mock_client do |_request|
        call_count += 1
        run_id = call_count < 3 ? nil : 77
        Protocol::HTTP::Response[200, [["content-type", "application/json"]],
                                 [JSON.generate({ id: 1, status: "running", run_id: run_id })]]
      end

      run_id = Space::Architect::JobsClient.new("http://localhost", "tok", client: client)
        .wait_for_run_id(1, interval: 0, attempts: 5)

      assert_equal 77, run_id
      assert_equal 3, call_count

      client.close
      server_task.stop
    end
  end

  # (k) wait_for_run_id raises Space::Core::Error once the poll bound (attempts)
  # is exceeded without a run_id ever appearing.
  def test_wait_for_run_id_raises_after_bound_exceeded
    Sync do
      client, server_task = mock_client do |_request|
        Protocol::HTTP::Response[200, [["content-type", "application/json"]],
                                 [JSON.generate({ id: 1, status: "pending", run_id: nil })]]
      end

      creator = Space::Architect::JobsClient.new("http://localhost", "tok", client: client)
      assert_raises(Space::Core::Error) { creator.wait_for_run_id(1, interval: 0, attempts: 3) }

      client.close
      server_task.stop
    end
  end
end
