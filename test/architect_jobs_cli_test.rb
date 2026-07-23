# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "json"

# CLI-level tests for `architect jobs list|show|watch|cancel`, exercised
# end-to-end via invoke() against a raw TCPServer stub (the house precedent
# for HTTP-through-the-CLI, see architect_cli_test.rb's dispatch push tests).
# Unlike that precedent, the stub's accept loop runs as an Async task (a
# fiber) rather than a Thread — no real reactor is spun up inside JobsClient
# by invoke() unless the accept loop is already inside one (Kernel#Sync
# reuses the current Async::Task if present), so wrapping the whole test in
# one outer Sync block lets the server fiber and the CLI's outbound request
# cooperate without ever touching Thread.
class ArchitectJobsCLITest < Space::ArchitectTest
  def start_stub(responses)
    tcp_server = TCPServer.new("127.0.0.1", 0)
    port = tcp_server.addr[1]
    requests = []

    server_task = Async do
      responses.each do |response|
        socket = tcp_server.accept
        request_line = socket.gets
        method, path, = request_line.split(" ")
        headers = {}
        while (line = socket.gets) && !line.chomp.empty?
          key, value = line.chomp.split(": ", 2)
          headers[key.downcase] = value
        end
        requests << { method: method, path: path, headers: headers }
        socket.write(response)
        socket.close
      end
    end

    [port, requests, server_task, tcp_server]
  end

  def json_response(status, body)
    payload = JSON.generate(body)
    "HTTP/1.1 #{status} #{Net_HTTP_STATUS[status]}\r\ncontent-type: application/json\r\ncontent-length: #{payload.bytesize}\r\nconnection: close\r\n\r\n#{payload}"
  end

  def sse_response(events)
    payload = events.map { |ev| "data: #{JSON.generate(ev)}\n\n" }.join
    "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: #{payload.bytesize}\r\nconnection: close\r\n\r\n#{payload}"
  end

  Net_HTTP_STATUS = { 200 => "OK", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 409 => "Conflict" }.freeze

  # (a) `jobs list` GETs /jobs with the Bearer header and renders an aligned table,
  # with Harness/Model/Lane provenance columns sourced from the list JSON's top-level
  # harness/model and nested provenance.lane (see server/app/actions/jobs/index.rb) —
  # and rendered blank, not crashing, for an older row that carries none of them.
  def test_jobs_list_requests_and_renders_table
    setup = temp_env
    with_env(setup[:env]) do
      Sync do
        port, requests, server_task, tcp_server = start_stub([
          json_response(200, { jobs: [
            { id: 1, status: "running", run_id: 4, created_at: "2026-07-19T00:00:00Z",
              harness: "claude", model: "sonnet",
              provenance: { space: "s1", iteration: "I16", lane: "server" } },
            { id: 2, status: "queued", run_id: nil, created_at: "2026-07-19T00:05:00Z" }
          ] })
        ])

        out, err = invoke("jobs", "list", "--host", "http://127.0.0.1:#{port}", "--token", "secret-token")
        server_task.wait
        tcp_server.close

        assert_empty err
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_equal "GET",  requests[0][:method]
        assert_equal "/jobs", requests[0][:path]
        assert_equal "Bearer secret-token", requests[0][:headers]["authorization"]

        header, row1, row2 = out.lines.map(&:rstrip)
        assert_match(/\bID\b.*\bHarness\b.*\bModel\b.*\bLane\b/, header)

        assert_match(/\b1\b/,   row1)
        assert_match(/running/, row1)
        assert_match(/\b4\b/,   row1)
        assert_match(/claude/,  row1)
        assert_match(/sonnet/,  row1)
        assert_match(/server/,  row1)

        assert_match(/\b2\b/, row2)
        assert_match(/queued/, row2)
        refute_match(/claude|sonnet|server/, row2)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (b) `jobs list` with no jobs prints a clear no-op message and exits 0.
  def test_jobs_list_empty
    setup = temp_env
    with_env(setup[:env]) do
      Sync do
        port, _requests, server_task, tcp_server = start_stub([json_response(200, { jobs: [] })])

        out, err = invoke("jobs", "list", "--host", "http://127.0.0.1:#{port}", "--token", "tok")
        server_task.wait
        tcp_server.close

        assert_empty err
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_match(/No jobs/, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (c) `jobs show <id>` GETs /jobs/:id and prints the job's JSON fields.
  def test_jobs_show_requests_and_renders_json
    setup = temp_env
    with_env(setup[:env]) do
      Sync do
        port, requests, server_task, tcp_server = start_stub([
          json_response(200, { id: 42, status: "pending", run_id: nil })
        ])

        out, err = invoke("jobs", "show", "42", "--host", "http://127.0.0.1:#{port}", "--token", "secret-token")
        server_task.wait
        tcp_server.close

        assert_empty err
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_equal "GET",      requests[0][:method]
        assert_equal "/jobs/42", requests[0][:path]
        assert_equal "Bearer secret-token", requests[0][:headers]["authorization"]
        parsed = JSON.parse(out)
        assert_equal 42, parsed["id"]
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (d) `jobs show <id>` surfaces a 404 as a nonzero exit via handle_errors.
  def test_jobs_show_404_exits_nonzero
    setup = temp_env
    with_env(setup[:env]) do
      Sync do
        port, _requests, server_task, tcp_server = start_stub([json_response(404, { error: "not found" })])

        out, err = invoke("jobs", "show", "999", "--host", "http://127.0.0.1:#{port}", "--token", "tok")
        server_task.wait
        tcp_server.close

        assert_equal "", out
        refute_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_match(/404/, err)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (e) `jobs cancel <id>` POSTs /jobs/:id/cancel and prints the server response.
  def test_jobs_cancel_requests_and_renders_response
    setup = temp_env
    with_env(setup[:env]) do
      Sync do
        port, requests, server_task, tcp_server = start_stub([
          json_response(200, { id: 5, status: "canceled" })
        ])

        out, err = invoke("jobs", "cancel", "5", "--host", "http://127.0.0.1:#{port}", "--token", "secret-token")
        server_task.wait
        tcp_server.close

        assert_empty err
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_equal "POST",           requests[0][:method]
        assert_equal "/jobs/5/cancel", requests[0][:path]
        assert_equal "Bearer secret-token", requests[0][:headers]["authorization"]
        parsed = JSON.parse(out)
        assert_equal "canceled", parsed["status"]
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (f) `jobs cancel <id>` surfaces a 409 (already terminal) as a nonzero exit.
  def test_jobs_cancel_409_exits_nonzero
    setup = temp_env
    with_env(setup[:env]) do
      Sync do
        port, _requests, server_task, tcp_server = start_stub([json_response(409, { error: "already terminal" })])

        _out, err = invoke("jobs", "cancel", "5", "--host", "http://127.0.0.1:#{port}", "--token", "tok")
        server_task.wait
        tcp_server.close

        refute_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_match(/409/, err)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (g) `jobs watch <id>` resolves run_id via show (already present — no
  # polling needed), then GETs /runs/:id/stream and prints each SSE event's
  # data: payload, exiting 0 at run_complete.
  def test_jobs_watch_resolves_run_id_then_streams_to_run_complete
    setup = temp_env
    with_env(setup[:env]) do
      Sync do
        port, requests, server_task, tcp_server = start_stub([
          json_response(200, { id: 1, status: "running", run_id: 9 }),
          sse_response([{ type: "message_start" }, { type: "run_complete" }])
        ])

        out, err = invoke("jobs", "watch", "1", "--host", "http://127.0.0.1:#{port}", "--token", "secret-token")
        server_task.wait
        tcp_server.close

        assert_empty err
        assert_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_equal "GET",             requests[0][:method]
        assert_equal "/jobs/1",         requests[0][:path]
        assert_equal "GET",             requests[1][:method]
        assert_equal "/runs/9/stream",  requests[1][:path]
        assert_equal "Bearer secret-token", requests[1][:headers]["authorization"]
        assert_match(/message_start/,  out)
        assert_match(/run_complete/,   out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (h) `jobs watch <id>` surfaces an auth error (401) on the stream request
  # as a nonzero exit, per the recorded exit semantics.
  def test_jobs_watch_stream_auth_error_exits_nonzero
    setup = temp_env
    with_env(setup[:env]) do
      Sync do
        port, _requests, server_task, tcp_server = start_stub([
          json_response(200, { id: 1, status: "running", run_id: 9 }),
          json_response(401, { error: "Sign in required." })
        ])

        _out, err = invoke("jobs", "watch", "1", "--host", "http://127.0.0.1:#{port}", "--token", "bad-token")
        server_task.wait
        tcp_server.close

        refute_equal 0, Space::Architect::CLI.last_outcome&.exit_code
        assert_match(/401/, err)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # (i) --host/--token are required — omitting either fails dry-cli's own
  # option validation before any request is made.
  def test_jobs_list_requires_host_and_token
    setup = temp_env
    with_env(setup[:env]) do
      _out, err = invoke("jobs", "list", "--token", "tok")
      refute_equal 0, Space::Architect::CLI.last_outcome&.exit_code
      assert_match(/host/i, err)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end
end
