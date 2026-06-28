# frozen_string_literal: true

require_relative "../test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "space/server/runs/stream_fanout"
require "space/server/runs/stream_key"

class StreamFanoutTest < Minitest::Test
  REDIS_SKIP_MSG = "Redis unreachable".freeze

  # Small delay to let XREAD BLOCK register in Redis before XADD fires.
  # Without this, XADD may reach Redis before the XREAD subscription is set
  # up, causing XREAD to use the newly-added entry as its "$" baseline and
  # block waiting for entries that will never come in the test.
  XREAD_SETTLE_SECONDS = 0.05

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
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :runs, :users].each { |t| conn[t].delete }
    @user = Factory[:user]
  end

  # Provide two separate Redis clients: one for the fanout's XREAD BLOCK (holds the
  # connection open), one for test-driven XADDs.
  def with_two_redis_clients
    Sync do
      fanout_redis = Async::Redis::Client.new(redis_endpoint)
      test_redis   = Async::Redis::Client.new(redis_endpoint)
      begin
        yield fanout_redis, test_redis
      ensure
        fanout_redis.close
        test_redis.close
      end
    end
  end

  def test_subscribed_queue_receives_entries_after_xadd
    run = Factory[:run, user_id: @user.id, status: 0]
    key = Space::Server::Runs::StreamKey.for(run.id)

    with_two_redis_clients do |fanout_redis, test_redis|
      test_redis.del(key)
      fanout = Space::Server::Runs::StreamFanout.for(run.id, fanout_redis)
      queue = fanout.subscribe

      Async do
        sleep XREAD_SETTLE_SECONDS
        test_redis.xadd(key, "*", "type", "text_delta", "data", '{"text":"hi"}')
      end

      item = queue.pop(timeout: 5)
      refute_nil item, "Expected queue to receive an entry within 5s"
      entry_id, fields = item
      type_idx = fields.index("type")
      assert_equal "text_delta", fields[type_idx + 1]
    ensure
      fanout&.unsubscribe(queue) if queue
      Space::Server::Runs::StreamFanout.stop(run.id)
    end
  end

  def test_multiple_subscribers_each_receive_same_entries
    run = Factory[:run, user_id: @user.id, status: 0]
    key = Space::Server::Runs::StreamKey.for(run.id)

    with_two_redis_clients do |fanout_redis, test_redis|
      test_redis.del(key)
      fanout = Space::Server::Runs::StreamFanout.for(run.id, fanout_redis)
      queue1 = fanout.subscribe
      queue2 = fanout.subscribe

      Async do
        sleep XREAD_SETTLE_SECONDS
        test_redis.xadd(key, "*", "type", "text_delta", "data", "{}")
      end

      item1 = queue1.pop(timeout: 5)
      item2 = queue2.pop(timeout: 5)

      refute_nil item1, "First subscriber must receive the entry"
      refute_nil item2, "Second subscriber must receive the entry"
      assert_equal item1[0], item2[0], "Both subscribers must receive the same entry id"
    ensure
      fanout&.unsubscribe(queue1) if queue1
      fanout&.unsubscribe(queue2) if queue2
      Space::Server::Runs::StreamFanout.stop(run.id)
    end
  end

  def test_unsubscribe_removes_queue_and_stops_task_on_last_unsubscribe
    run = Factory[:run, user_id: @user.id, status: 0]
    key = Space::Server::Runs::StreamKey.for(run.id)

    with_two_redis_clients do |fanout_redis, test_redis|
      test_redis.del(key)
      fanout = Space::Server::Runs::StreamFanout.for(run.id, fanout_redis)
      queue1 = fanout.subscribe
      queue2 = fanout.subscribe

      # Unsubscribe one — task stays alive
      fanout.unsubscribe(queue1)

      Async do
        sleep XREAD_SETTLE_SECONDS
        test_redis.xadd(key, "*", "type", "text_delta", "data", "{}")
      end

      # queue2 still receives; queue1 does not (it's removed)
      item = queue2.pop(timeout: 5)
      refute_nil item, "Remaining subscriber must still receive entries"

      # Unsubscribe last subscriber — task should stop
      fanout.unsubscribe(queue2)

      # Verify no more broadcasts: XADD another entry, new queue gets nothing via fan-out
      test_redis.xadd(key, "*", "type", "text_delta", "data", "{}")
      Async::Task.current.yield

      assert_equal 0, fanout.instance_variable_get(:@subscribers).length
    ensure
      Space::Server::Runs::StreamFanout.stop(run.id)
    end
  end

  def test_run_complete_entry_stops_fanout_after_pushing_to_queues
    run = Factory[:run, user_id: @user.id, status: 0]
    key = Space::Server::Runs::StreamKey.for(run.id)

    with_two_redis_clients do |fanout_redis, test_redis|
      test_redis.del(key)
      fanout = Space::Server::Runs::StreamFanout.for(run.id, fanout_redis)
      queue = fanout.subscribe

      Async do
        sleep XREAD_SETTLE_SECONDS
        test_redis.xadd(key, "*", "type", "run_complete", "data", "{}")
      end

      item = queue.pop(timeout: 5)
      refute_nil item, "Subscriber must receive run_complete entry"
      _, fields = item
      type_idx = fields.index("type")
      assert_equal "run_complete", fields[type_idx + 1]

      # Give the fanout task time to process the break after run_complete
      Async::Task.current.yield
      Async::Task.current.yield

      # XADD another entry — fan-out task stopped, queue should not receive it
      test_redis.xadd(key, "*", "type", "text_delta", "data", "{}")
      next_item = queue.pop(timeout: 1)
      assert_nil next_item, "No entries expected after run_complete stops the fanout"
    ensure
      fanout&.unsubscribe(queue) if queue
      Space::Server::Runs::StreamFanout.stop(run.id)
    end
  end

  # Characterization: double-unsubscribe is safe — Array#delete is a no-op on a
  # missing element and @task&.stop is safe on nil. Already correct on base.
  def test_characterization_double_unsubscribe_does_not_raise
    run = Factory[:run, user_id: @user.id, status: 0]
    key = Space::Server::Runs::StreamKey.for(run.id)

    with_two_redis_clients do |fanout_redis, _test_redis|
      fanout = Space::Server::Runs::StreamFanout.for(run.id, fanout_redis)
      queue = fanout.subscribe

      fanout.unsubscribe(queue)
      # Second unsubscribe on the same queue must not raise.
      fanout.unsubscribe(queue)
      assert true, "double unsubscribe must not raise"
    ensure
      Space::Server::Runs::StreamFanout.stop(run.id)
    end
  end

  def test_for_returns_same_instance_for_same_run_id
    run = Factory[:run, user_id: @user.id, status: 0]

    Sync do
      client = Async::Redis::Client.new(redis_endpoint)
      begin
        fanout1 = Space::Server::Runs::StreamFanout.for(run.id, client)
        fanout2 = Space::Server::Runs::StreamFanout.for(run.id, client)
        assert_same fanout1, fanout2, "for() must return the same instance for the same run_id"
      ensure
        Space::Server::Runs::StreamFanout.stop(run.id)
        client.close
      end
    end
  end
end
