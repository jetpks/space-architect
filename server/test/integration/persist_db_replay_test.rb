# frozen_string_literal: true

# Real-HTTP + real-PG + real-Redis integration test for the DB-replay path (DoD #3).
#
# Ingests a multi-message fixture (text, tool_use, tool_result block types) over real
# HTTP so the Persistor runs for real.  Then clears the Redis stream key to simulate
# TTL expiry and asserts that GET /runs/:id/stream replays from the DB via db_replay.
#
# AC-P3 faithfulness: reverting stream.rb lines 53-54 (the db_replay cutover) to a
# no-op causes the stream body proc to enter the queue loop and never emit run_complete
# within the test timeout, making the assert_match below FAIL.

require_relative "../test_helper"
require "rack/mock"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "protocol/rack/adapter"
require "protocol/http/body/buffered"
require "space/server/runs/stream_fanout"
require "space/server/runs/stream_key"

Space::Server::App.start(:redis)

class PersistDbReplayTest < Minitest::Test
  FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "claude_code_stream_tooluse.jsonl"))
  FIXTURE_EVENT_COUNT = 21  # confirmed: normalizer produces 21 events from the tooluse fixture
  TOKEN = "persist-db-replay-integration-test-deadbeef0123"

  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :runs, :users].each { |t| conn[t].delete }
    @user  = Factory[:user]
    @run   = Factory[:run, user_id: @user.id, status: 0, published: true]
    @redis = Space::Server::App["redis"]
    Sync { @redis.call("DEL", "run:#{@run.id}") }
  end

  def test_ingest_persists_db_and_stream_replays_after_redis_expiry
    settings      = Space::Server::App["settings"]
    runs_repo     = Space::Server::App["repos.runs_repo"]
    messages_repo = Space::Server::App["repos.messages_repo"]
    port          = 50100 + rand(400)
    endpoint      = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

    settings.stub(:ingest_token, TOKEN) do
      settings.stub(:ingest_user_id, @user.id) do
        Sync do |task|
          server_task = task.async do
            Async::HTTP::Server.new(Protocol::Rack::Adapter.new(Space::Server::App), endpoint).run
          rescue => _e
            nil
          end

          begin
            task.sleep(0.3)
            client = Async::HTTP::Client.new(endpoint)

            task.with_timeout(30) do
              # ── Phase 1: Ingest via real HTTP ──────────────────────────────────

              headers  = Protocol::HTTP::Headers.new([
                ["content-type",  "application/x-ndjson"],
                ["authorization", "Bearer #{TOKEN}"]
              ])
              body     = Protocol::HTTP::Body::Buffered.wrap(FIXTURE_JSONL)
              response = client.post("/runs/#{@run.id}/ingest", headers, body)
              raw      = response.read || ""
              response.finish

              assert_equal 202, response.status
              data = JSON.parse(raw)
              assert_equal "complete", data["status"],
                "ingest must complete (fixture has a result line)"
              assert_equal FIXTURE_EVENT_COUNT, data["events"],
                "fixture must produce #{FIXTURE_EVENT_COUNT} normalized events"

              # ── Phase 2: Assert incremental DB persistence ─────────────────────

              run = runs_repo.by_pk(@run.id)
              assert run.complete?,         "run must be complete after ingest"
              refute_nil run.conversation_id, "run must have conversation_id after ingest"

              msgs = messages_repo.for_conversation(run.conversation_id)
              assert_equal 3, msgs.size, "tooluse fixture produces 3 DB messages"
              assert_equal [0, 1, 2], msgs.map(&:position), "positions must be sequential"

              # Correct order after persistor fix: assistant turn first, then tool_result user
              assert_equal "assistant", msgs[0].role, "position 0 must be assistant (text+tool_use)"
              assert_equal "user",      msgs[1].role, "position 1 must be user (tool_result)"
              assert_equal "assistant", msgs[2].role, "position 2 must be second assistant (text)"

              # Block type coverage — all three types must round-trip through JSONB
              assert msgs[0].content.any? { |b| b["type"] == "text" },
                "assistant msg at pos 0 must have text block"
              assert msgs[0].content.any? { |b| b["type"] == "tool_use" },
                "assistant msg at pos 0 must have tool_use block"
              assert msgs[1].content.any? { |b| b["type"] == "tool_result" },
                "user msg at pos 1 must have tool_result block"
              assert msgs[2].content.any? { |b| b["type"] == "text" },
                "assistant msg at pos 2 must have text block"

              # ── Phase 3: Simulate Redis TTL expiry ────────────────────────────

              @redis.call("DEL", Space::Server::Runs::StreamKey.for(run.id))

              # ── Phase 4: GET stream — must replay from DB via db_replay ────────
              #
              # AC-P3 proof: if stream.rb lines 53-54 are reverted to a no-op, the
              # body proc enters the queue loop (queue.pop timeout=15s), never emits
              # run_complete, the 8-second timeout fires, and assert_match below fails.

              env = Rack::MockRequest.env_for(
                "/runs/#{run.id}/stream",
                "REQUEST_METHOD" => "GET"
              )
              _, _, body_proc = Space::Server::App.call(env)

              chunks = []
              mock_stream = Object.new.tap do |s|
                s.define_singleton_method(:<<) { |d| chunks << d; s }
                s.define_singleton_method(:close) { |_e = nil| }
              end

              begin
                task.with_timeout(8) do
                  body_proc.call(mock_stream)
                end
              rescue Async::TimeoutError
                # db_replay missing → stream loops on heartbeat; timeout = test fail below
              ensure
                Space::Server::Runs::StreamFanout.stop(run.id)
              end

              sse = chunks.join

              assert_match "run_complete", sse,
                "SSE replay must terminate with run_complete " \
                "(AC-P3: reverting stream.rb lines 53-54 makes this fail)"
              assert_match "I'll read the README.md file.", sse,
                "SSE replay must include first assistant text content"
              assert_match "tool_use", sse,
                "SSE replay must include tool_use block events"
              assert_match "tool_result", sse,
                "SSE replay must include tool_result events"
              assert_match "space-architect-server", sse,
                "SSE replay must include second assistant text content"

              # Events must arrive in ascending id order (db_replay uses 0-1, 0-2, ...)
              ids = sse.scan(/^id: ([\d-]+)/).flatten
              refute_empty ids, "SSE must contain id: lines"
              assert_equal ids, ids.sort_by { |id| id.split("-").map(&:to_i) },
                "SSE event ids must be in ascending order"
              assert_equal "0-#{ids.size}", ids.last,
                "last SSE id must match total event count"
            end
          ensure
            client&.close rescue nil
            server_task.stop
          end
        end
      end
    end
  end
end
