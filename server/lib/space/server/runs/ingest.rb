# frozen_string_literal: true

require "json"
require_relative "stream_key"
require_relative "../normalizer"

module Space
  module Server
    module Runs
      class Ingest
        MAXLEN = "10000"

        def initialize(redis, persistor: nil, source: nil)
          @redis     = redis
          @persistor = persistor
          @source    = source
        end

        # Reads JSONL lines from input (rack.input / StringIO / any IO responding to #gets),
        # normalizes each via Space::Server::Normalizer, XADDs each event onto the run's Redis
        # stream, and refreshes the TTL per XADD.  When a persistor is provided, also creates
        # a conversation (tagged with the optional source) and persists messages incrementally.
        # Returns { events: count, status: :complete|:failed|:live }.
        def call(run, input)
          key = StreamKey.for(run.id)
          setup_persistor(run)
          parser = nil
          event_count = 0
          final_status = :live
          terminal_emitted = false

          while (line = input.gets)
            line = line.strip
            next if line.empty?

            record = JSON.parse(line) rescue next
            parser ||= Normalizer.select(record).new
            events = parser.process(record)
            events.each do |event|
              xadd(key, event)
              @persistor&.process(event)
              event_count += 1
              if event[:type] == :run_complete
                final_status = :complete
                terminal_emitted = true
              end
            end

            break if final_status == :complete
          end

          xadd(key, { type: :run_complete }) unless terminal_emitted
          { events: event_count, status: final_status }
        rescue => e
          begin
            xadd(key, { type: :run_complete }) unless terminal_emitted
          rescue
            nil
          end
          { events: event_count, status: :failed, error: e.message }
        end

        private

        # A nil source defers to Persistor#setup's own default.
        def setup_persistor(run)
          return unless @persistor

          @source ? @persistor.setup(run, source: @source) : @persistor.setup(run)
        end

        def xadd(key, event)
          @redis.xadd(key, "MAXLEN", "~", MAXLEN, "*", "type", event[:type].to_s, "data", JSON.generate(event))
          @redis.expire(key, StreamKey::TTL_SECONDS)
        end
      end
    end
  end
end
