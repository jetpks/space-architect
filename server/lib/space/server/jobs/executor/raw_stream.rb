# frozen_string_literal: true

require "json"
require_relative "../stream_key"

module Space
  module Server
    module Jobs
      class Executor
        # The frozen raw-stream wire contract (consumer lane reads these exact
        # literals): key job:<job_id>:raw (owned by Jobs::StreamKey), XADD fields
        # type + data, MAXLEN ~10000, TTL 1800 s refreshed per XADD (mirror of
        # runs/ingest.rb).
        # type: "out" | "err" (one verbatim harness line) | "exit" (terminal,
        # exactly once per execution attempt, data = {"code": <int>}).
        class RawStream
          MAXLEN = "10000"

          def initialize(redis, job_id)
            @redis = redis
            @key   = StreamKey.for(job_id)
          end

          def out(line) = add("out", line)
          def err(line) = add("err", line)
          def exit(code) = add("exit", JSON.generate(code: code))

          # Clears any stale stream from a prior attempt at this job id — a
          # requeued job (crash → lease-expire → sweep → re-claim) must start
          # from an empty stream, not append onto the surviving transcript.
          def reset = @redis.del(@key)

          private

          def add(type, data)
            @redis.xadd(@key, "MAXLEN", "~", MAXLEN, "*", "type", type, "data", data)
            @redis.expire(@key, StreamKey::TTL_SECONDS)
          end
        end
      end
    end
  end
end
