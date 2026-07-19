# frozen_string_literal: true

require "json"

module Space
  module Server
    module Jobs
      class Consumer
        # IO-shaped reader over an executor raw stream (wire contract: key
        # job:<job_id>:raw, XADD fields type + data, type = out | err | exit).
        #
        # #gets returns the next harness stdout line (an `out` payload) and nil
        # at EOF — the terminal `exit` frame, or a quiet stream once the
        # producer is gone. `err` payloads are dropped: stderr is not part of
        # the transcript. Reads block cooperatively (XREAD BLOCK in 1s slices,
        # per the StreamFanout idiom) so a drain fiber waits patiently on a
        # live producer without ever hanging forever on a dead one.
        class RawStream
          BLOCK_MS = "1000"

          attr_reader :exit_code

          def initialize(redis, job_id, abandoned: -> { false })
            @redis     = redis
            @key       = "job:#{job_id}:raw"
            @abandoned = abandoned
            @last_id   = "0"
            @buffer    = []
            @exit_code = nil
            @eof       = false
          end

          def gets
            until @eof
              type, data = next_entry
              case type
              when "out" then return data
              when "err" then next
              when "exit"
                @exit_code = parse_exit(data)
                @eof = true
              when nil
                @eof = true
              end
            end
            nil
          end

          # Ingest stops reading at run_complete (the harness result line), which
          # lands before the executor's exit frame — consume the remainder so the
          # exit code is known.
          def drain_to_exit
            nil while gets
            @exit_code
          end

          private

          def next_entry
            while @buffer.empty?
              results = @redis.xread("BLOCK", BLOCK_MS, "STREAMS", @key, @last_id)
              if results.nil? || results.empty?
                return nil if @abandoned.call
              else
                @buffer.concat(results.first[1])
              end
            end

            entry_id, fields = @buffer.shift
            @last_id = entry_id
            pairs = fields.each_slice(2).to_h
            [pairs["type"], pairs["data"]]
          end

          def parse_exit(data)
            parsed = JSON.parse(data.to_s)
            parsed.is_a?(Hash) ? parsed["code"] : nil
          rescue JSON::ParserError
            nil
          end
        end
      end
    end
  end
end
