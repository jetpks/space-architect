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

  # Production passes ONE shared Async::Redis::Client instance to every StreamFanout
  # (config/providers/redis.rb registers a singleton; actions/runs/stream.rb injects it
  # into every StreamFanout.for call). `with_two_redis_clients` above gives each fanout
  # its own dedicated client/pool, which never reproduces pool-sharing defects. These two
  # tests instead share ONE client across multiple fanouts, like production does.
  def with_shared_redis_client
    Sync do
      shared_redis = Async::Redis::Client.new(redis_endpoint)
      test_redis   = Async::Redis::Client.new(redis_endpoint)
      begin
        yield shared_redis, test_redis
      ensure
        shared_redis.close
        test_redis.close
      end
    end
  end

  # AC2(a): a subscriber established before an XADD receives that entry, riding the same
  # shared client production uses (previously only exercised via dedicated per-fanout
  # clients above, or via catch-up/resume paths in runs_test.rb).
  def test_subscriber_established_before_xadd_receives_entry_on_shared_client
    run = Factory[:run, user_id: @user.id, status: 0]
    key = Space::Server::Runs::StreamKey.for(run.id)

    with_shared_redis_client do |shared_redis, test_redis|
      test_redis.del(key)
      fanout = Space::Server::Runs::StreamFanout.for(run.id, shared_redis)
      queue = fanout.subscribe

      Async do
        sleep XREAD_SETTLE_SECONDS
        test_redis.xadd(key, "*", "type", "text_delta", "data", '{"text":"hi"}')
      end

      item = queue.pop(timeout: 5)
      refute_nil item, "Expected queue to receive an entry within 5s (subscriber established before XADD)"
    ensure
      fanout&.unsubscribe(queue) if queue
      Space::Server::Runs::StreamFanout.stop(run.id)
    end
  end

  # AC2(b): after a prior subscriber's fanout loop is stopped mid-XREAD BLOCK (the
  # disconnect path — subscribe, let the loop block with nothing ever written, then
  # unsubscribe before any entry arrives), a NEW fanout for a DIFFERENT run, riding the
  # SAME shared client, must still receive its own XADD promptly.
  #
  # Pre-fix: StreamFanout#start runs its XREAD BLOCK loop on the shared `@redis`. Stopping
  # the task mid-`read_response` unwinds through async-pool's `acquire { }` block, which
  # `release`s the connection back into the shared pool looking healthy — but Redis still
  # owes it a response for the abandoned blocking XREAD. The next fanout's `acquire` draws
  # that same connection and its own XREAD queues forever behind a block that never
  # returns (see stream_fanout.rb's `start` and the CLIENT LIST `qbuf` smoking gun this
  # iteration's grounds describe).
  def test_poisoned_connection_does_not_starve_a_different_runs_fanout
    poisoned_run = Factory[:run, user_id: @user.id, status: 0]
    fresh_run    = Factory[:run, user_id: @user.id, status: 0]
    poisoned_key = Space::Server::Runs::StreamKey.for(poisoned_run.id)
    fresh_key    = Space::Server::Runs::StreamKey.for(fresh_run.id)

    with_shared_redis_client do |shared_redis, test_redis|
      test_redis.del(poisoned_key)
      test_redis.del(fresh_key)

      # Poison: subscribe with nothing ever written, let the XREAD BLOCK register with
      # Redis, then abandon it mid-block — simulates a client disconnecting before any
      # data arrives (the exact path StreamFanout#unsubscribe/#stop takes on every SSE
      # client disconnect).
      poisoned_fanout = Space::Server::Runs::StreamFanout.for(poisoned_run.id, shared_redis)
      poisoned_queue = poisoned_fanout.subscribe
      sleep XREAD_SETTLE_SECONDS
      poisoned_fanout.unsubscribe(poisoned_queue)
      Async::Task.current.yield

      # A different run's fanout, riding the same shared client, must still work.
      fresh_fanout = Space::Server::Runs::StreamFanout.for(fresh_run.id, shared_redis)
      fresh_queue = fresh_fanout.subscribe

      Async do
        sleep XREAD_SETTLE_SECONDS
        test_redis.xadd(fresh_key, "*", "type", "text_delta", "data", '{"text":"fresh"}')
      end

      item = fresh_queue.pop(timeout: 5)
      refute_nil item, "A new run's fanout must not be starved by a prior poisoned shared-pool connection"
    ensure
      fresh_fanout&.unsubscribe(fresh_queue) if fresh_queue
      Space::Server::Runs::StreamFanout.stop(poisoned_run.id)
      Space::Server::Runs::StreamFanout.stop(fresh_run.id)
    end
  end
end
