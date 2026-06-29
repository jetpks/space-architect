# frozen_string_literal: true

require "json"
require_relative "event"

module Space
  module Server
    module Normalizer
      # Stateful parser for opencode sessions stored in SQLite.
      # Consumes one opencode message + its ordered parts, returns an Event array.
      # Sibling to ClaudeSession — reuses Event; does NOT fork it.
      class OpencodeSession
        def initialize(session_id: nil, session_dir: nil)
          @session_id       = session_id
          @session_dir      = session_dir
          @run_init_emitted = false
        end

        # Accepts a message Hash: { "id" => msg_id, "data" => parsed_Hash, "parts" => [...] }
        # Returns [] for nil/garbage data without raising.
        def process(message)
          data  = message["data"]
          parts = Array(message["parts"])
          return [] unless data.is_a?(Hash)

          events = []

          unless @run_init_emitted
            cwd = data.dig("path", "root") || @session_dir
            events << Event.make(:run_init, session_id: @session_id, cwd: cwd)
            @run_init_emitted = true
          end

          events.concat(dispatch(data, parts, message["id"]))
        end

        private

        def dispatch(data, parts, msg_id)
          case data["role"]
          when "assistant" then handle_assistant(data, parts, msg_id)
          when "user"      then handle_user(parts)
          else []
          end
        end

        def handle_assistant(data, parts, msg_id)
          events = [Event.make(:message_start,
            message_id: msg_id,
            model:      data["modelID"],
            role:       "assistant",
            usage:      data["tokens"])]

          step_finish = parts.find { |p| p.is_a?(Hash) && p["type"] == "step-finish" }

          parts.each_with_index do |part, i|
            next unless part.is_a?(Hash)
            block_id = i.to_s

            case part["type"]
            when "text"
              events << Event.make(:block_open,  block_id: block_id, index: i, block_type: :text,     name: nil, tool_use_id: nil)
              events << Event.make(:text_delta,  block_id: block_id, text: part["text"].to_s)
              events << Event.make(:block_close, block_id: block_id)
            when "reasoning"
              events << Event.make(:block_open,  block_id: block_id, index: i, block_type: :thinking,  name: nil, tool_use_id: nil)
              events << Event.make(:text_delta,  block_id: block_id, text: part["text"].to_s)
              events << Event.make(:block_close, block_id: block_id)
            when "tool"
              call_id = part["callID"]
              events << Event.make(:block_open,       block_id: block_id, index: i, block_type: :tool_use, name: part["tool"], tool_use_id: call_id)
              events << Event.make(:tool_args_delta,  block_id: block_id, partial_json: JSON.generate(part.dig("state", "input") || {}))
              events << Event.make(:block_close,      block_id: block_id)
              events << Event.make(:tool_result,
                tool_use_id: call_id,
                content:     part.dig("state", "output").to_s,
                is_error:    part.dig("state", "status") == "error")
            # step-start, step-finish, patch, unknown → skip
            end
          end

          stop_reason = step_finish ? Event.normalize_stop_reason(step_finish["reason"]) : :end_turn
          events << Event.make(:message_complete, message_id: msg_id, stop_reason: stop_reason)
          events
        end

        def handle_user(parts)
          text = parts.select { |p| p.is_a?(Hash) && p["type"] == "text" }
                      .map { |p| p["text"].to_s }
                      .join
          return [] if text.empty?
          user_text_message(text)
        end

        def user_text_message(text)
          block_id = "0"
          [
            Event.make(:message_start, role: "user"),
            Event.make(:block_open,  block_id: block_id, index: 0, block_type: :text, name: nil, tool_use_id: nil),
            Event.make(:text_delta,  block_id: block_id, text: text),
            Event.make(:block_close, block_id: block_id),
            Event.make(:message_complete, stop_reason: :end_turn)
          ]
        end
      end
    end
  end
end
