# frozen_string_literal: true

# Integration tests for the terminal-run cutover boundary (AC-4).
#
# Verifies that GET /runs/:id/stream ALWAYS terminates with run_complete for any
# terminal run (complete or failed) — never hanging in the live-tail loop.
#
# Two decisive fail-on-base cases:
#   (i)  FAILED run (status 3) with a persisted conversation, Redis DEL'd —
#        replays persisted messages + run_complete, never hangs.
#   (ii) COMPLETE run (status 2) with conversation_id nil, Redis DEL'd —
#        emits a synthetic run_complete and closes, never hangs.
#
# AC-4 proof: reverting the stream.rb cutover change causes both cases to enter
# the live-tail loop (queue.pop timeout=15s), never emit run_complete within the
# 8-second task timeout, and fail on the assert_match below.

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

class TerminalRunReplayTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :runs, :users].each { |t| conn[t].delete }
    @user      = Factory[:user]
    @redis     = Space::Server::App["redis"]
    @runs_repo = Space::Server::App["repos.runs_repo"]
  end

  # Stream /runs/:id/stream via Rack mock, with an 8-second bounded timeout.
  # Returns the concatenated SSE body (or partial if timeout fires).
  def stream_sse(run)
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

    Sync do |task|
      begin
        task.with_timeout(8) do
          body_proc.call(mock_stream)
        end
      rescue Async::TimeoutError
        # live-tail loop hung → SSE will lack run_complete → assert_match below fails
      ensure
        Space::Server::Runs::StreamFanout.stop(run.id)
      end
    end

    chunks.join
  end

  # (i) FAILED run with a persisted conversation, Redis stream DEL'd.
  # Must replay persisted message(s) + run_complete and terminate.
  def test_failed_run_with_conversation_replays_and_terminates
    conv = Factory[:conversation, user_id: @user.id]
    Factory[:message,
      conversation_id: conv.id,
      role: "assistant",
      content: [{ "type" => "text", "text" => "terminal-run-replay-fixture" }],
      position: 0
    ]

    run_record = Factory[:run, user_id: @user.id, status: 0, published: true]
    @runs_repo.update(run_record.id, status: 3, conversation_id: conv.id)
    run = @runs_repo.by_pk(run_record.id)

    Sync { @redis.call("DEL", Space::Server::Runs::StreamKey.for(run.id)) }

    sse = stream_sse(run)

    assert_match "run_complete", sse,
      "FAILED run with conversation must replay and terminate with run_complete " \
      "(AC-4: reverting stream.rb cutover makes this hang and fail)"
    assert_match "terminal-run-replay-fixture", sse,
      "FAILED run replay must include persisted message content"
  end

  # (ii) COMPLETE run with conversation_id nil, Redis stream DEL'd.
  # Must emit a synthetic run_complete frame and close.
  def test_complete_run_without_conversation_emits_terminal_and_closes
    run_record = Factory[:run, user_id: @user.id, status: 0, published: true]
    @runs_repo.update(run_record.id, status: 2)
    run = @runs_repo.by_pk(run_record.id)

    Sync { @redis.call("DEL", Space::Server::Runs::StreamKey.for(run.id)) }

    sse = stream_sse(run)

    assert_match "run_complete", sse,
      "COMPLETE run with nil conversation_id must emit run_complete and close " \
      "(AC-4: reverting stream.rb cutover makes this hang and fail)"
  end
end
