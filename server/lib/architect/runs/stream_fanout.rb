# frozen_string_literal: true

require "async"
require "async/queue"
require_relative "stream_key"

module Architect
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
        stop if @subscribers.empty?
      end

      def stop
        @task&.stop
        @task = nil
      end

      private

      def start
        return if @task&.alive?
        @task = Async do
          key = StreamKey.for(@run_id)
          last_id = "$"
          done = false
          loop do
            results = @redis.xread("BLOCK", "0", "STREAMS", key, last_id)
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
        end
      end
    end
  end
end
