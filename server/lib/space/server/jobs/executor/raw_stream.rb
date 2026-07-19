# frozen_string_literal: true

require "json"

module Space
  module Server
    module Jobs
      class Executor
        # The frozen raw-stream wire contract (consumer lane reads these exact
        # literals): key job:<job_id>:raw, XADD fields type + data, MAXLEN ~10000,
        # TTL 1800 s refreshed per XADD (mirror of runs/ingest.rb).
        # type: "out" | "err" (one verbatim harness line) | "exit" (terminal,
        # exactly once per execution attempt, data = {"code": <int>}).
        class RawStream
          MAXLEN      = "10000"
          TTL_SECONDS = 1800

          def self.key_for(job_id) = "job:#{job_id}:raw"

          def initialize(redis, job_id)
            @redis = redis
            @key   = self.class.key_for(job_id)
          end

          def out(line) = add("out", line)
          def err(line) = add("err", line)
          def exit(code) = add("exit", JSON.generate(code: code))

          private

          def add(type, data)
            @redis.xadd(@key, "MAXLEN", "~", MAXLEN, "*", "type", type, "data", data)
            @redis.expire(@key, TTL_SECONDS)
          end
        end
      end
    end
  end
end
