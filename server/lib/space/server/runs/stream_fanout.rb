# frozen_string_literal: true

require "async"
require "async/queue"
require "async/redis"
require_relative "stream_key"

module Space
  module Server
    module Runs
      class StreamFanout
        HEARTBEAT_SECONDS = 15

        @registry = {}

        def self.for(run_id, redis)
          @registry[run_id] ||= new(run_id, redis)
        end

        def self.stop(run_id)
          @registry.delete(run_id)&.stop
        end

        def initialize(run_id, redis)
          @run_id = run_id
          @redis = redis
          @subscribers = []
          @task = nil
        end

        def subscribe
          queue = Async::Queue.new
          @subscribers << queue
          start
          queue
        end

        def unsubscribe(queue)
          @subscribers.delete(queue)
          self.class.stop(@run_id) if @subscribers.empty?
        end

        def stop
          @task&.stop
          @task = nil
        end

        private

        def start
          return if @task&.alive?
          @task = Async do
            # This loop's XREAD BLOCK 0 parks a connection with Redis indefinitely.
            # Riding the shared, pooled `@redis` for that would be a defect: stopping
            # this loop mid-block (a client disconnect) unwinds through async-pool's
            # `acquire { }`, which releases the connection back into the shared pool
            # looking healthy — but Redis still owes it a response for the abandoned
            # block. The next fanout to acquire that connection queues forever behind
            # a block that never returns. A dedicated client — created for this loop,
            # closed (never released to a pool) on every exit — has nothing to share
            # and nothing to poison. Mirrors Context::Subscription's own-connection
            # pattern in async-redis (context/subscription.rb: explicit `@connection.close`
            # ahead of `release`).
            dedicated = Async::Redis::Client.new(@redis.endpoint, protocol: @redis.protocol)
            begin
              key = StreamKey.for(@run_id)
              last_id = "$"
              done = false
              loop do
                results = dedicated.xread("BLOCK", "0", "STREAMS", key, last_id)
                break if results.nil? || results.empty?

                entries = results.first[1]
                entries.each do |entry_id, fields|
                  last_id = entry_id
                  @subscribers.each { |q| q << [entry_id, fields] }

                  type_idx = fields.index("type")
                  if type_idx && fields[type_idx + 1] == "run_complete"
                    done = true
                    break
                  end
                end
                break if done
              end
            ensure
              dedicated.close
            end
          end
        end
      end
    end
  end
end
