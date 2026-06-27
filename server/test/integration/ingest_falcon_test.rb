# frozen_string_literal: true

# Real-HTTP integration test for POST /runs/:id/ingest.
#
# Boots an in-process Async::HTTP::Server + Protocol::Rack::Adapter serving the
# real Architect::App (same code path as Falcon in production), so rack.input is
# a genuine Protocol::Rack::Input wrapping a Protocol::HTTP1::Body::Fixed — the
# non-rewindable one-shot body that the Rack::MockRequest tests never exercise.
#
# Two properties under test:
#   1. Happy path: response events == fixture count AND Redis XLEN == fixture count.
#   2. Streaming preservation: zero Protocol::Rack::Input#read calls before the
#      action (proves the router's _params did NOT drain the body).

require_relative "../test_helper"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "protocol/rack/adapter"
require "protocol/http/body/buffered"

Architect::App.start(:redis)

# Install once at load time: track Protocol::Rack::Input#read calls whose
# backtrace is outside Architect::Runs::Ingest (i.e. pre-action drains).
# Cleared in setup before each test.
INGEST_FALCON_PRE_ACTION_READS = []

Protocol::Rack::Input.prepend(Module.new do
  def read(*args)
    unless caller(1, 20).any? { |l| l.include?("runs/ingest") }
      INGEST_FALCON_PRE_ACTION_READS << caller(1, 8).join("\n")
    end
    super
  end
end)

class IngestFalconTest < Minitest::Test
  FIXTURE_JSONL = File.read(File.join(__dir__, "..", "fixtures", "files", "claude_code_stream_text.jsonl"))
  # Expected event count is what the normalizer emits, not raw line count.
  # Computed once using a noop redis so no side effects at load time.
  FIXTURE_EVENT_COUNT = begin
    noop = Object.new
    def noop.xadd(*); end
    def noop.expire(*); end
    Architect::Runs::Ingest.new(noop).call(
      Struct.new(:id).new(0),
      StringIO.new(FIXTURE_JSONL)
    )[:events]
  end
  TOKEN = "ingest-falcon-integration-test-deadbeef0123"

  def setup
    conn = Architect::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :runs, :users].each { |t| conn[t].delete }
    @user  = Factory[:user]
    @run   = Factory[:run, user_id: @user.id, status: 0]
    @redis = Architect::App["redis"]
    Sync { @redis.call("DEL", "run:#{@run.id}") }
    INGEST_FALCON_PRE_ACTION_READS.clear
  end

  # Boots a real Protocol::Rack::Adapter server, POSTs the JSONL fixture with a
  # valid bearer, and asserts the happy path + streaming-preservation property.
  def test_full_body_ingested_and_not_drained_before_action
    settings = Architect::App["settings"]
    port     = 49200 + rand(700)
    endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{port}")

    settings.stub(:ingest_token, TOKEN) do
      settings.stub(:ingest_user_id, @user.id) do
        Sync do |task|
          server_task = task.async do
            Async::HTTP::Server.new(Protocol::Rack::Adapter.new(Architect::App), endpoint).run
          rescue => _e
            nil
          end

          begin
            # Bounded readiness: yield to the reactor so the server can bind its socket.
            task.sleep(0.3)

            client = Async::HTTP::Client.new(endpoint)

            task.with_timeout(15) do
              headers = Protocol::HTTP::Headers.new([
                ["content-type",  "application/x-ndjson"],
                ["authorization", "Bearer #{TOKEN}"]
              ])
              body     = Protocol::HTTP::Body::Buffered.wrap(FIXTURE_JSONL)
              response = client.post("/runs/#{@run.id}/ingest", headers, body)
              raw      = response.read || ""
              response.finish

              assert_equal 202, response.status

              data = JSON.parse(raw)
              assert_equal FIXTURE_EVENT_COUNT, data["events"],
                "AC5: response events must equal fixture count (#{FIXTURE_EVENT_COUNT})"

              xlen = @redis.call("XLEN", "run:#{@run.id}")
              assert_equal FIXTURE_EVENT_COUNT, xlen,
                "AC5: Redis XLEN must equal fixture count (#{FIXTURE_EVENT_COUNT})"

              # AC6: body must not have been drained by the router before the action.
              assert_equal 0, INGEST_FALCON_PRE_ACTION_READS.size,
                "AC6: Protocol::Rack::Input#read called before action (pre-action drain); " \
                "first trace:\n#{INGEST_FALCON_PRE_ACTION_READS.first}"
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
