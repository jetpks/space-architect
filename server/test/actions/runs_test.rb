# frozen_string_literal: true

require_relative "action_test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "architect/runs/stream_fanout"
require "architect/runs/stream_key"

class RunsActionTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @owner   = Factory[:user, github_uid: "owner-uid", username: "owner"]
    @other   = Factory[:user, github_uid: "other-uid", username: "other"]
    @runs_repo = Architect::App["repos.runs_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  # --- POST /runs ---

  def test_create_anon_returns_401
    status, _, body = post("/runs")
    assert_equal 401, status
    data = parse_json(body)
    assert data.key?("error")
  end

  def test_create_signed_in_returns_201_with_pending_json
    sign_in(@owner)
    status, headers, body = post("/runs")
    assert_equal 201, status
    assert_equal "application/json; charset=utf-8", headers["content-type"]
    data = parse_json(body)
    assert data.key?("id"),             "response must include id"
    assert_equal "pending", data["status"], "status must be pending"
  end

  def test_create_persists_run_with_correct_user_and_status
    sign_in(@owner)
    _, _, body = post("/runs")
    data = parse_json(body)
    run = @runs_repo.by_pk(data["id"])
    refute_nil run, "run must be persisted"
    assert_equal @owner.id, run.user_id, "run user_id must match owner"
    assert_equal :pending, run.status,   "run status must be :pending (0)"
  end

  # --- POST /runs/:id/ingest ---

  def test_ingest_missing_run_returns_404
    status, _, _ = post("/runs/99999/ingest")
    assert_equal 404, status
  end

  def test_ingest_anon_returns_401
    run = Factory[:run, user_id: @owner.id, status: 0]
    status, _, body = post("/runs/#{run.id}/ingest")
    assert_equal 401, status
    data = parse_json(body)
    assert data.key?("error")
  end

  def test_ingest_non_owner_returns_403
    run = Factory[:run, user_id: @owner.id, status: 0]
    sign_in(@other)
    status, _, body = post("/runs/#{run.id}/ingest")
    assert_equal 403, status
    data = parse_json(body)
    assert data.key?("error")
  end

  MINIMAL_JSONL = "{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"/test\",\"session_id\":\"test\",\"tools\":[],\"model\":\"test\"}\n"
  FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "claude_code_stream_text.jsonl"))

  def test_ingest_owner_with_jsonl_body_returns_202_and_events
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 0]
    Sync do
      status, headers, body = post_raw("/runs/#{run.id}/ingest", body: FIXTURE_JSONL)
      assert_equal 202, status
      assert_equal "application/json; charset=utf-8", headers["content-type"]
      data = parse_json(body)
      assert_equal run.id, data["id"]
      assert data["events"] > 0, "Expected events > 0"
      assert_equal "complete", data["status"]
    end
  end

  def test_ingest_transitions_run_status_from_pending_to_live
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 0]
    post("/runs/#{run.id}/ingest")
    updated = @runs_repo.by_pk(run.id)
    refute_equal :pending, updated.status, "run status must not remain :pending after ingest"
  end

  def test_ingest_with_result_line_transitions_run_to_complete
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 0]
    Sync do
      post_raw("/runs/#{run.id}/ingest", body: FIXTURE_JSONL)
    end
    updated = @runs_repo.by_pk(run.id)
    assert_equal :complete, updated.status, "run status must be :complete when fixture contains result line"
  end

  def test_ingest_empty_body_returns_202_live_zero_events
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 0]
    status, _, body = post("/runs/#{run.id}/ingest")
    assert_equal 202, status
    data = parse_json(body)
    assert_equal 0, data["events"]
    assert_equal "live", data["status"]
  end

  def test_ingest_minimal_body_streams_run_init_event
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 0]
    Sync do
      status, _, body = post_raw("/runs/#{run.id}/ingest", body: MINIMAL_JSONL)
      assert_equal 202, status
      data = parse_json(body)
      assert_equal 1, data["events"]
      assert_equal "live", data["status"]
    end
  end

  # --- GET /runs/:id/stream ---

  def redis_endpoint
    url = ENV["REDIS_URL"]
    url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
  end

  def test_stream_missing_run_returns_404
    status, _, _ = get("/runs/99999/stream")
    assert_equal 404, status
  end

  def test_stream_anon_returns_401
    run = Factory[:run, user_id: @owner.id, status: 1, published: false]
    status, _, body = get("/runs/#{run.id}/stream")
    assert_equal 401, status
    data = parse_json(body)
    assert data.key?("error")
  end

  def test_stream_anon_on_published_returns_200
    run = Factory[:run, user_id: @owner.id, status: 1, published: true]
    status, headers, _ = get_stream("/runs/#{run.id}/stream")
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
  end

  def test_stream_non_owner_returns_403
    sign_in(@other)
    run = Factory[:run, user_id: @owner.id, status: 1, published: false]
    status, _, body = get("/runs/#{run.id}/stream")
    assert_equal 403, status
    data = parse_json(body)
    assert data.key?("error")
  end

  def test_stream_owner_returns_sse_headers
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 1, published: false]
    status, headers, _ = get_stream("/runs/#{run.id}/stream")
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
    assert_equal "no-cache", headers["cache-control"]
  end

  def test_stream_backlog_emits_sse_events
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Architect::Runs::StreamKey.for(run.id)
      redis_client.del(key)
      redis_client.xadd(key, "*", "type", "text_delta",   "data", '{"type":"text_delta","text":"hello"}')
      redis_client.xadd(key, "*", "type", "run_complete", "data", '{"type":"run_complete"}')

      _, _, body = get_stream("/runs/#{run.id}/stream")
      chunks = collect_sse_chunks(body, timeout: 5)

      text = chunks.join
      assert_match "id:", text
      assert_match "data:", text
      assert chunks.any? { |c| c.include?("text_delta") }, "Expected text_delta event"
      assert chunks.any? { |c| c.include?("run_complete") }, "Expected run_complete event"
    ensure
      redis_client&.close
      Architect::Runs::StreamFanout.stop(run.id)
    end
  end

  def test_stream_live_tail_delivers_entries_via_fanout
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Architect::Runs::StreamKey.for(run.id)
      redis_client.del(key)

      _, _, body = get_stream("/runs/#{run.id}/stream")
      chunks = []
      mock_stream = MockStream.new(chunks)

      body_task = Async do
        begin
          body.call(mock_stream)
        rescue
        end
      end

      # Sleep briefly to let XREAD BLOCK register in Redis before XADD fires;
      # without this the XADD may arrive before XREAD's "$" baseline is set.
      sleep 0.05

      # XADD live entries — fan-out XREAD will pick them up
      redis_client.xadd(key, "*", "type", "text_delta",   "data", '{"type":"text_delta","text":"live"}')
      redis_client.xadd(key, "*", "type", "run_complete", "data", '{"type":"run_complete"}')

      # Wait for proc to finish (run_complete terminates the loop)
      body_task.wait
      text = chunks.join
      assert_match "text_delta", text
      assert_match "run_complete", text
    ensure
      redis_client&.close
      Architect::Runs::StreamFanout.stop(run.id)
    end
  end

  def test_stream_run_complete_terminates_body_proc
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 2]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Architect::Runs::StreamKey.for(run.id)
      redis_client.del(key)
      redis_client.xadd(key, "*", "type", "message_start", "data", '{"type":"message_start"}')
      redis_client.xadd(key, "*", "type", "run_complete",  "data", '{"type":"run_complete"}')

      _, _, body = get_stream("/runs/#{run.id}/stream")
      chunks = collect_sse_chunks(body, timeout: 5)

      assert chunks.any? { |c| c.include?("run_complete") }, "run_complete must appear in SSE output"
      # proc must have terminated — if chunks is empty the proc never ran; either way no timeout
    ensure
      redis_client&.close
      Architect::Runs::StreamFanout.stop(run.id)
    end
  end

  def test_stream_last_event_id_skips_earlier_entries
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Architect::Runs::StreamKey.for(run.id)
      redis_client.del(key)

      first_entry  = redis_client.xadd(key, "*", "type", "text_delta",   "data", '{"seq":1}')
      _            = redis_client.xadd(key, "*", "type", "text_delta",   "data", '{"seq":2}')
      _            = redis_client.xadd(key, "*", "type", "run_complete", "data", '{"type":"run_complete"}')

      # Resume from first_entry — should only deliver the 2nd and run_complete
      _, _, body = get_stream("/runs/#{run.id}/stream",
                              extra_env: { "HTTP_LAST_EVENT_ID" => first_entry })
      chunks = collect_sse_chunks(body, timeout: 5)

      text = chunks.join
      # seq:1 entry was the resume point; must not appear
      refute_match(/seq.*1/, text)
      # seq:2 and run_complete must appear; run_complete data contains type
      assert_match "seq\":2", text
      assert_match "run_complete", text
    ensure
      redis_client&.close
      Architect::Runs::StreamFanout.stop(run.id)
    end
  end

  # Characterization: resume at the boundary — Last-Event-ID equals the last entry in
  # the stream, so XRANGE returns empty; the next XADD is delivered via live fanout
  # with no gap and no duplicate. Already correct on base.
  def test_characterization_resume_boundary_empty_backlog_live_delivers_next
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Architect::Runs::StreamKey.for(run.id)
      redis_client.del(key)

      # Seed one entry; the client will reconnect from its id.
      seed_id = redis_client.xadd(key, "*", "type", "text_delta", "data", '{"seq":0}')

      _, _, body = get_stream("/runs/#{run.id}/stream",
                              extra_env: { "HTTP_LAST_EVENT_ID" => seed_id })
      chunks = []
      mock_stream = MockStream.new(chunks)

      body_task = Async do
        begin
          body.call(mock_stream)
        rescue
        end
      end

      # Let XREAD BLOCK register before XADD fires.
      sleep 0.05

      # This entry is the first one AFTER the resume point — must be delivered live.
      redis_client.xadd(key, "*", "type", "run_complete", "data", '{"type":"run_complete"}')

      body_task.wait
      text = chunks.join
      # Seed entry (seq:0) must NOT appear — it was the resume point, not sent.
      refute_match(/seq.*0/, text)
      # run_complete must appear.
      assert_match "run_complete", text
    ensure
      redis_client&.close
      Architect::Runs::StreamFanout.stop(run.id)
    end
  end

  # Characterization: reconnect with overlapping live writes — entries XADD'd between
  # subscribe and XRANGE replay cleanly from backlog; the live-dedup guard
  # (stream.rb: `next if last_id && entry_id <= last_id`) prevents double-delivery.
  # Already correct on base.
  def test_characterization_resume_overlapping_live_write_no_gap_no_duplicate
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Architect::Runs::StreamKey.for(run.id)
      redis_client.del(key)

      first_id = redis_client.xadd(key, "*", "type", "text_delta", "data", '{"seq":1}')
      _         = redis_client.xadd(key, "*", "type", "text_delta", "data", '{"seq":2}')
      _         = redis_client.xadd(key, "*", "type", "run_complete", "data", '{"type":"run_complete"}')

      # Resume from first_id; seq:2 and run_complete come from backlog.
      _, _, body = get_stream("/runs/#{run.id}/stream",
                              extra_env: { "HTTP_LAST_EVENT_ID" => first_id })
      chunks = collect_sse_chunks(body, timeout: 5)

      text = chunks.join
      # seq:1 was the resume point — must not appear.
      refute_match(/seq.*1/, text)
      # seq:2 must appear exactly once.
      occurrences = text.scan("seq").length
      assert_equal 1, occurrences, "seq:2 must appear exactly once (no duplicate from live overlap)"
      assert_match "run_complete", text
    ensure
      redis_client&.close
      Architect::Runs::StreamFanout.stop(run.id)
    end
  end

  # Characterization: disconnect teardown — the ensure block always unsubscribes the
  # queue and closes the stream, even when the fanout task is mid-XREAD BLOCK. The
  # per-run fiber is cancelled when the last subscriber leaves. Already correct on base.
  def test_characterization_disconnect_teardown_stops_fanout_task
    sign_in(@owner)
    run = Factory[:run, user_id: @owner.id, status: 1]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Architect::Runs::StreamKey.for(run.id)
      redis_client.del(key)

      # Stream has no entries yet; body proc will block on fanout.
      _, _, body = get_stream("/runs/#{run.id}/stream")
      chunks = []
      closed_with_error = false
      mock_stream = Class.new do
        define_method(:<<) { |_| }
        define_method(:close) { |err| closed_with_error = !err.nil? }
      end.new

      fanout = Architect::Runs::StreamFanout.for(run.id, redis_client)

      body_task = Async do
        body.call(mock_stream)
      end

      # Cancel the body task (simulates client disconnect).
      sleep 0.05
      body_task.stop
      body_task.wait rescue nil

      # After disconnect, the fanout task must be stopped (no alive task).
      Async::Task.current.yield
      task = fanout.instance_variable_get(:@task)
      assert task.nil? || !task.alive?, "Fanout task must be stopped after last subscriber disconnects"
    ensure
      redis_client&.close
      Architect::Runs::StreamFanout.stop(run.id)
    end
  end

  def test_stream_db_fallback_replays_messages_when_redis_expired
    sign_in(@owner)
    conversations_repo = Architect::App["repos.conversations_repo"]
    messages_repo      = Architect::App["repos.messages_repo"]

    conv = conversations_repo.create(
      user_id: @owner.id, status: 0, published: false,
      created_at: Time.now, updated_at: Time.now
    )
    messages_repo.create(
      conversation_id: conv.id, role: "assistant",
      content: [{ "type" => "text", "text" => "hello from db" }],
      position: 0, published: false,
      created_at: Time.now, updated_at: Time.now
    )

    run = Factory[:run, user_id: @owner.id, status: 2, conversation_id: conv.id]

    Sync do
      redis_client = Async::Redis::Client.new(redis_endpoint)
      key = Architect::Runs::StreamKey.for(run.id)
      redis_client.del(key)

      _, _, body = get_stream("/runs/#{run.id}/stream")
      chunks = collect_sse_chunks(body, timeout: 5)

      text = chunks.join
      assert_match "run_complete", text
      assert_match "hello from db", text
    ensure
      redis_client&.close
      Architect::Runs::StreamFanout.stop(run.id)
    end
  end
end
