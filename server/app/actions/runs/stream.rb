# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Runs
        class Stream < Space::Server::Action
          include Space::Server::Deps["repos.runs_repo", "repos.messages_repo", "redis"]

          def handle(req, res)
            run = runs_repo.by_pk(req.params[:id].to_i)
            halt_not_found(res) unless run

            user = authenticated_user(req)

            unless run.visible_to?(user)
              res.content_type = JSON_CONTENT_TYPE
              if user
                halt 403, JSON.generate(error: "Not authorized.")
              else
                halt 401, JSON.generate(error: "Sign in required.")
              end
            end

            res.status = 200
            res.headers["content-type"] = "text/event-stream"
            res.headers["cache-control"] = "no-cache"
            res.headers["x-accel-buffering"] = "no"

            last_event_id = req.get_header("HTTP_LAST_EVENT_ID")
            fanout = Space::Server::Runs::StreamFanout.for(run.id, redis)

            body = proc do |stream|
              queue = fanout.subscribe
              last_id = nil
              error = nil

              begin
                key = Space::Server::Runs::StreamKey.for(run.id)
                start_id = last_event_id ? "(#{last_event_id}" : "-"
                entries = redis.xrange(key, start_id, "+")
                done = false
                entries&.each do |entry_id, fields|
                  last_id = entry_id
                  stream << sse_format(entry_id, fields)
                  type_idx = fields.index("type")
                  if type_idx && fields[type_idx + 1] == "run_complete"
                    done = true
                    break
                  end
                end

                # DB fallback: Redis stream expired, run is terminal (complete or failed)
                if !done && (run.complete? || run.failed?)
                  if run.conversation_id
                    done = db_replay(stream, messages_repo.for_conversation(run.conversation_id))
                  else
                    stream << sse_format(nil, ["type", "run_complete", "data", JSON.generate(type: "run_complete")])
                    done = true
                  end
                end

                unless done
                  loop do
                    item = queue.pop(timeout: Space::Server::Runs::StreamFanout::HEARTBEAT_SECONDS)
                    if item.nil?
                      stream << ": ping\n\n"
                      next
                    end

                    entry_id, fields = item
                    next if last_id && entry_id <= last_id

                    last_id = entry_id
                    stream << sse_format(entry_id, fields)

                    type_idx = fields.index("type")
                    break if type_idx && fields[type_idx + 1] == "run_complete"
                  end
                end
              rescue => error
              ensure
                fanout.unsubscribe(queue)
                stream.close(error)
              end
            end

            res.instance_variable_set(:@body, body)
          end

          private

          # entry_id: a real Redis stream id, or nil to omit the `id:` field entirely.
          # An SSE event with no `id:` line leaves the client's Last-Event-ID
          # untouched — required for db_replay events below, which have no real
          # stream position to alias (see #db_replay).
          def sse_format(entry_id, fields)
            data_idx = fields.index("data")
            data = data_idx ? fields[data_idx + 1] : "{}"
            id_line = entry_id ? "id: #{entry_id}\n" : ""
            "#{id_line}data: #{data}\n\n"
          end

          # Replays a completed conversation from Postgres when the Redis display
          # stream has expired. These events carry no `id:` field (see #sse_format):
          # a fabricated id (e.g. "0-1") would alias a real Redis stream position,
          # and a client that adopts it as Last-Event-ID would later reconnect with
          # `XRANGE ((0-N` against the real stream — an exclusive lower bound below
          # every real entry, so it replays the whole thing.
          def db_replay(stream, messages)
            messages.each do |msg|
              msg_event = { type: "message_start", role: msg.role, model: msg.model }.compact
              stream << sse_format(nil, ["type", "message_start", "data", JSON.generate(msg_event)])

              Array(msg.content).each_with_index do |block, i|
                block_id = i.to_s
                case block["type"]
                when "text"
                  stream << sse_format(nil, ["type", "block_open",  "data", JSON.generate(type: "block_open",  block_id: block_id, index: i, block_type: "text")])
                  stream << sse_format(nil, ["type", "text_delta",  "data", JSON.generate(type: "text_delta",  block_id: block_id, text: block["text"].to_s)])
                  stream << sse_format(nil, ["type", "block_close", "data", JSON.generate(type: "block_close", block_id: block_id)])
                when "tool_use"
                  stream << sse_format(nil, ["type", "block_open",     "data", JSON.generate(type: "block_open",     block_id: block_id, index: i, block_type: "tool_use", name: block["name"], tool_use_id: block["id"])])
                  stream << sse_format(nil, ["type", "tool_args_delta","data", JSON.generate(type: "tool_args_delta", block_id: block_id, partial_json: JSON.generate(block["input"] || {}))])
                  stream << sse_format(nil, ["type", "block_close",    "data", JSON.generate(type: "block_close",    block_id: block_id)])
                when "tool_result"
                  stream << sse_format(nil, ["type", "tool_result", "data", JSON.generate(type: "tool_result", tool_use_id: block["tool_use_id"], content: block["content"], is_error: block["is_error"])])
                end
              end

              stream << sse_format(nil, ["type", "message_complete", "data", JSON.generate(type: "message_complete", stop_reason: "end_turn")])
            end

            stream << sse_format(nil, ["type", "run_complete", "data", JSON.generate(type: "run_complete")])
            true
          end
        end
      end
    end
  end
end
