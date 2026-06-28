# frozen_string_literal: true

require "json"
require_relative "event"

module Space
  module Server
    module Normalizer
      # Stateful parser for Claude Code session-log JSONL files
      # (~/.claude/projects/<project>/<session-uuid>.jsonl).
      #
      # Session logs differ from builder dispatch streams:
      #   - Every record carries "sessionId" (camelCase) and often "cwd".
      #   - Envelope wraps a Anthropic message object in "message".
      #   - Each assistant record typically contains ONE content block; multiple
      #     records sharing the same msg.id form one logical turn.
      #   - isSidechain records are skipped (sub-agent threading deferred to I03).
      class ClaudeSession
        def initialize
          @run_init_emitted = false
        end

        # Accepts a raw JSON String or a pre-parsed Hash.
        # Empty/blank strings and unparseable JSON return [] without raising.
        def process(line)
          record = line.is_a?(Hash) ? line : parse_json(line)
          return [] unless record
          return [] if record["isSidechain"]

          events = []

          unless @run_init_emitted
            if record["sessionId"] && record["cwd"]
              events << Event.make(:run_init, session_id: record["sessionId"], cwd: record["cwd"])
              @run_init_emitted = true
            end
          end

          events.concat(dispatch(record))
        end

        private

        def parse_json(str)
          return nil if str.nil? || str.to_s.strip.empty?
          JSON.parse(str.strip)
        rescue JSON::ParserError
          nil
        end

        def dispatch(record)
          case record["type"]
          when "assistant" then handle_assistant(record)
          when "user"      then handle_user(record)
          else []
          end
        end

        # ── assistant ─────────────────────────────────────────────────────────────
        # Mirrors ClaudeCode#handle_assistant (non-partial path).
        # Thinking → text_delta; text → text_delta; tool_use → tool_args_delta.

        def handle_assistant(record)
          msg = record["message"]
          return [] unless msg

          message_id = msg["id"]
          events = [Event.make(:message_start,
            message_id: message_id,
            model:      msg["model"],
            role:       msg["role"] || "assistant",
            usage:      msg["usage"])]

          Array(msg["content"]).each_with_index do |block, i|
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
              events << Event.make(:tool_args_delta,
                block_id:     block_id,
                partial_json: JSON.generate(block["input"] || {}))
            end

            events << Event.make(:block_close, block_id: block_id)
          end

          events << Event.make(:message_complete,
            message_id:  message_id,
            stop_reason: Event.normalize_stop_reason(msg["stop_reason"]),
            usage:       msg["usage"])
          events
        end

        # ── user ──────────────────────────────────────────────────────────────────
        # String content → role:"user" text message.
        # Array content: text blocks → role:"user" text message; tool_result blocks → :tool_result.

        def handle_user(record)
          msg = record["message"]
          return [] unless msg

          content = msg["content"]
          events  = []

          if content.is_a?(String)
            events.concat(user_text_message(content))
          else
            text_blocks   = Array(content).select { |b| b["type"] == "text" }
            result_blocks = Array(content).select { |b| b["type"] == "tool_result" }

            text = text_blocks.map { |b| b["text"].to_s }.join
            events.concat(user_text_message(text)) unless text.empty?

            result_blocks.each { |b| events << tool_result_event(b) }
          end

          events
        end

        def user_text_message(text)
          block_id = "0"
          [
            Event.make(:message_start, role: "user"),
            Event.make(:block_open, block_id: block_id, index: 0, block_type: :text,
                                    name: nil, tool_use_id: nil),
            Event.make(:text_delta, block_id: block_id, text: text),
            Event.make(:block_close, block_id: block_id),
            Event.make(:message_complete, stop_reason: :end_turn)
          ]
        end

        def tool_result_event(block)
          raw = block["content"]
          content = raw.is_a?(Array) ?
            raw.filter_map { |c| c["text"] if c["type"] == "text" }.join :
            raw.to_s

          Event.make(:tool_result,
            tool_use_id: block["tool_use_id"],
            content:     content,
            is_error:    block["is_error"] == true)
        end
      end
    end
  end
end
