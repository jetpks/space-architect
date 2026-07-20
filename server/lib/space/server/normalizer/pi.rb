# frozen_string_literal: true

require "json"
require_relative "event"

module Space
  module Server
    module Normalizer
      # Stateful parser for pi's `--mode json` line stream (one JSON object per
      # LF line, no run_complete-style sentinel — EOF + exit code end the stream;
      # see Runs::Ingest#complete_at_eof? below).
      #
      # message_end always carries the message's COMPLETE final content (like
      # ClaudeCode's non-partial "assistant" record), so it is treated as the
      # sole source of block/message events; message_start and message_update
      # are recognized but inert (message_update's assistantMessageEvent delta
      # vocabulary is unverified beyond a single thinking_delta example, and
      # re-deriving content from it would risk double-emitting what message_end
      # already supplies in full). tool_execution_end is the canonical source of
      # tool_result (fires before the redundant message_end role: "toolResult"
      # pair, which is skipped to avoid double emission). agent_end carries the
      # full message array again and turn_end replays the last message — both
      # skipped for the same reason. agent_settled is stream-final but carries no
      # payload of its own; completion is driven by EOF, not this record.
      class Pi
        def process(line)
          record = line.is_a?(Hash) ? line : parse_json(line)
          return [] unless record

          dispatch(record)
        end

        # Duck-typed by Runs::Ingest: pi's stream has no completion sentinel, so
        # reaching clean EOF (no read error) after this parser was ever used is
        # itself the completion signal — the real success/failure arbiter is the
        # harness exit code, checked downstream in Jobs::Consumer.
        def complete_at_eof? = true

        private

        def parse_json(str)
          return nil if str.nil? || str.to_s.strip.empty?
          JSON.parse(str.strip)
        rescue JSON::ParserError
          nil
        end

        def dispatch(record)
          case record["type"]
          when "session"            then handle_session(record)
          when "message_end"        then handle_message_end(record)
          when "tool_execution_end" then handle_tool_execution_end(record)
          else []
          end
        end

        def handle_session(record)
          [Event.make(:run_init, session_id: record["id"], cwd: record["cwd"])]
        end

        def handle_message_end(record)
          message = record["message"] || {}
          case message["role"]
          when "assistant" then assistant_lifecycle(message)
          else [] # "user" (the initial prompt, already known to the caller) and "toolResult" (tool_execution_end)
          end
        end

        def assistant_lifecycle(message)
          events = [Event.make(:message_start, model: message["model"], role: "assistant", usage: message["usage"])]

          Array(message["content"]).each_with_index do |block, i|
            block_id   = i.to_s
            block_type = Event::BLOCK_TYPES.fetch(block["type"]) { block["type"].to_sym }

            events << Event.make(:block_open,
              block_id:    block_id,
              index:       i,
              block_type:  block_type,
              name:        block_type == :tool_use ? block["name"] : nil,
              tool_use_id: block_type == :tool_use ? block["id"]   : nil)

            case block_type
            when :text
              events << Event.make(:text_delta, block_id: block_id, text: block["text"].to_s)
            when :thinking
              events << Event.make(:text_delta, block_id: block_id, text: block["thinking"].to_s)
            when :tool_use
              events << Event.make(:tool_args_delta, block_id: block_id, partial_json: JSON.generate(block["arguments"] || {}))
            end

            events << Event.make(:block_close, block_id: block_id)
          end

          events << Event.make(:message_complete,
            stop_reason: Event.normalize_stop_reason(message["stopReason"]),
            usage:       message["usage"])
          events
        end

        def handle_tool_execution_end(record)
          result = record["result"] || {}
          [Event.make(:tool_result,
            tool_use_id: record["toolCallId"],
            content:     extract_text(result["content"]),
            is_error:    record["isError"] == true)]
        end

        def extract_text(content)
          case content
          when Array  then content.filter_map { |c| c["text"] if c.is_a?(Hash) && c["type"] == "text" }.join
          when String then content
          else ""
          end
        end
      end
    end
  end
end
