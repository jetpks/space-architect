# frozen_string_literal: true

require_relative "../test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "stringio"
require "architect/runs/ingest"
require "architect/runs/persistor"
require "architect/runs/stream_key"

class IngestTest < Minitest::Test
  REDIS_SKIP_MSG = "Redis unreachable".freeze
  FIXTURE = File.read(File.join(__dir__, "..", "fixtures", "files", "claude_code_stream_text.jsonl"))
  MINIMAL_JSONL = "{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"/test\",\"session_id\":\"test\",\"tools\":[],\"model\":\"test\"}\n"

  def redis_endpoint
    url = ENV["REDIS_URL"]
    url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
  end

  def redis_reachable?
    Sync do
      client = Async::Redis::Client.new(redis_endpoint)
      client.call("PING")
      client.close
      true
    rescue
      false
    end
  end

  def setup
    skip REDIS_SKIP_MSG unless redis_reachable?
    conn = Architect::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :runs, :users].each { |t| conn[t].delete }
    @user = Factory[:user]
  end

  def with_redis
    Sync do
      client = Async::Redis::Client.new(redis_endpoint)
      begin
        yield client
      ensure
        client.close
      end
    end
  end

  def test_events_appear_in_stream
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      key = Architect::Runs::StreamKey.for(run.id)
      redis.del(key)
      result = Architect::Runs::Ingest.new(redis).call(run, StringIO.new(FIXTURE))
      assert result[:events] > 0, "Expected events > 0, got #{result[:events]}"
      entries = redis.xrange(key, "-", "+")
      assert_equal result[:events], entries.length, "XRANGE count must match returned event count"
    end
  end

  def test_ttl_is_set_on_stream_key
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      key = Architect::Runs::StreamKey.for(run.id)
      redis.del(key)
      Architect::Runs::Ingest.new(redis).call(run, StringIO.new(FIXTURE))
      ttl = redis.ttl(key)
      assert ttl > 0, "Expected TTL > 0, got #{ttl}"
    end
  end

  def test_run_complete_event_returns_complete_status
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      result = Architect::Runs::Ingest.new(redis).call(run, StringIO.new(FIXTURE))
      assert_equal :complete, result[:status]
    end
  end

  def test_event_types_include_run_init_message_start_and_run_complete
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      key = Architect::Runs::StreamKey.for(run.id)
      redis.del(key)
      Architect::Runs::Ingest.new(redis).call(run, StringIO.new(FIXTURE))
      entries = redis.xrange(key, "-", "+")
      # Each entry: [id, [field, value, ...]] — type value is at index 1 in the fields array
      types = entries.map { |e| e[1][1] }
      assert_includes types, "run_init"
      assert_includes types, "message_start"
      assert_includes types, "run_complete"
    end
  end

  def test_empty_input_returns_zero_events_without_crash
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      result = Architect::Runs::Ingest.new(redis).call(run, StringIO.new(""))
      assert_equal 0, result[:events]
      assert_equal :live, result[:status]
    end
  end

  def test_stream_entries_have_type_and_data_fields
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      key = Architect::Runs::StreamKey.for(run.id)
      redis.del(key)
      Architect::Runs::Ingest.new(redis).call(run, StringIO.new(MINIMAL_JSONL))
      entries = redis.xrange(key, "-", "+")
      refute_empty entries, "Expected at least one stream entry"
      fields = entries.first[1]  # ["type", "run_init", "data", "{...}"]
      assert_includes fields, "type", "Expected 'type' field in stream entry"
      assert_includes fields, "data", "Expected 'data' field in stream entry"
    end
  end

  def test_data_field_is_valid_json
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      key = Architect::Runs::StreamKey.for(run.id)
      redis.del(key)
      Architect::Runs::Ingest.new(redis).call(run, StringIO.new(MINIMAL_JSONL))
      entries = redis.xrange(key, "-", "+")
      fields = entries.first[1]
      data_idx = fields.index("data")
      refute_nil data_idx, "Expected 'data' field"
      parsed = JSON.parse(fields[data_idx + 1])
      assert_equal "run_init", parsed["type"]
    end
  end

  # --- Persistor integration ---

  def test_ingest_with_persistor_creates_conversation
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      conversations_repo = Architect::App["repos.conversations_repo"]
      messages_repo      = Architect::App["repos.messages_repo"]
      persistor = Architect::Runs::Persistor.new(conversations_repo, messages_repo)
      Architect::Runs::Ingest.new(redis, persistor: persistor).call(run, StringIO.new(FIXTURE))
      refute_nil persistor.conversation_id
      conv = conversations_repo.by_pk(persistor.conversation_id)
      refute_nil conv
      assert_equal run.user_id, conv.user_id
    end
  end

  def test_ingest_with_persistor_persists_messages
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      conversations_repo = Architect::App["repos.conversations_repo"]
      messages_repo      = Architect::App["repos.messages_repo"]
      persistor = Architect::Runs::Persistor.new(conversations_repo, messages_repo)
      Architect::Runs::Ingest.new(redis, persistor: persistor).call(run, StringIO.new(FIXTURE))
      msgs = messages_repo.for_conversation(persistor.conversation_id)
      assert msgs.length > 0, "Expected at least one message persisted"
      roles = msgs.map(&:role).uniq
      assert_includes roles, "assistant"
    end
  end

  def test_ingest_without_persistor_still_works
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      result = Architect::Runs::Ingest.new(redis).call(run, StringIO.new(FIXTURE))
      assert_equal :complete, result[:status]
      assert result[:events] > 0
    end
  end

  # AC-3: INGEST SELF-TERMINATES — decisive fail-on-base tests

  def test_raising_io_leaves_terminal_run_complete_in_stream
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      key = Architect::Runs::StreamKey.for(run.id)
      redis.del(key)

      # IO yields one valid init line then raises on the second #gets call
      calls = 0
      io = Object.new
      io.define_singleton_method(:gets) do
        calls += 1
        raise "simulated read error" if calls > 1
        "{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"/t\",\"session_id\":\"s\",\"tools\":[],\"model\":\"m\"}\n"
      end

      result = Architect::Runs::Ingest.new(redis).call(run, io)
      assert_equal :failed, result[:status], "rescue path must return :failed"

      entries = redis.xrange(key, "-", "+")
      refute_empty entries, "stream must have entries after raising IO"
      last_type = entries.last[1][1]
      assert_equal "run_complete", last_type,
        "stream must end with run_complete terminal frame on rescue path (AC-3)"
    end
  end

  def test_eof_without_run_complete_leaves_terminal_frame_in_stream
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      key = Architect::Runs::StreamKey.for(run.id)
      redis.del(key)

      # MINIMAL_JSONL produces only run_init — no run_complete line
      Architect::Runs::Ingest.new(redis).call(run, StringIO.new(MINIMAL_JSONL))

      entries = redis.xrange(key, "-", "+")
      refute_empty entries
      last_type = entries.last[1][1]
      assert_equal "run_complete", last_type,
        "stream must end with run_complete even when input ends without one (AC-3)"
    end
  end

  def test_complete_run_does_not_double_emit_run_complete
    run = Factory[:run, user_id: @user.id, status: 0]
    with_redis do |redis|
      key = Architect::Runs::StreamKey.for(run.id)
      redis.del(key)
      Architect::Runs::Ingest.new(redis).call(run, StringIO.new(FIXTURE))
      entries = redis.xrange(key, "-", "+")
      complete_count = entries.count { |e| e[1][1] == "run_complete" }
      assert_equal 1, complete_count, "must have exactly one run_complete frame"
    end
  end
end
