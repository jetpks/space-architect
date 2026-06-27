# frozen_string_literal: true

require "json"
require_relative "event"

module Architect
  module Normalizer
    # Stateful parser for Claude Code stream-json output (and non-partial assistant records).
    # Feed lines one at a time via #process; returns an Array of 0+ normalized event hashes.
    class ClaudeCode
      def initialize
        @partial_mode = false  # true once the first stream_event is seen
        @blocks = {}           # index (Integer) => { id: String, type: Symbol }
        @current_message_id = nil
        @deferred_stop_reason = nil
        @deferred_usage = nil
      end

      # Accepts a raw JSON String or a pre-parsed Hash.
      # Empty/blank strings and unparseable JSON return [] without raising.
      def process(line)
        record = line.is_a?(Hash) ? line : parse_json(line)
        return [] unless record

        dispatch(record)
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
        when "system"           then handle_system(record)
        when "stream_event"     then handle_stream_event(record)
        when "assistant"        then handle_assistant(record)
        when "user"             then handle_user(record)
        when "result"           then handle_result(record)
        when "rate_limit_event" then []
        else []
        end
      end

      # ── system ────────────────────────────────────────────────────────────────

      def handle_system(record)
        return [] unless record["subtype"] == "init"
        [Event.make(:run_init,
          session_id: record["session_id"],
          model:      record["model"],
          cwd:        record["cwd"],
          tools:      record["tools"])]
      end

      # ── stream_event ──────────────────────────────────────────────────────────

      def handle_stream_event(record)
        @partial_mode = true
        event = record["event"]
        return [] unless event

        case event["type"]
        when "message_start"       then handle_message_start(event)
        when "content_block_start" then handle_content_block_start(event)
        when "content_block_delta" then handle_content_block_delta(event)
        when "content_block_stop"  then handle_content_block_stop(event)
        when "message_delta"       then handle_message_delta(event)
        when "message_stop"        then handle_message_stop(event)
        else []
        end
      end

      def handle_message_start(event)
        msg = event["message"]
        @current_message_id = msg&.dig("id")
        [Event.make(:message_start,
          message_id: @current_message_id,
          model:      msg&.dig("model"),
          role:       msg&.dig("role") || "assistant",
          usage:      msg&.dig("usage"))]
      end

      def handle_content_block_start(event)
        index      = event["index"]
        block      = event["content_block"]
        block_id   = index.to_s
        block_type = Event::BLOCK_TYPES.fetch(block["type"]) { block["type"].to_sym }

        @blocks[index] = { id: block_id, type: block_type }

        [Event.make(:block_open,
          block_id:    block_id,
          index:       index,
          block_type:  block_type,
          name:        block_type == :tool_use ? block["name"] : nil,
          tool_use_id: block_type == :tool_use ? block["id"]   : nil)]
      end

      def handle_content_block_delta(event)
        index = event["index"]
        block = @blocks[index]
        return [] unless block

        delta = event["delta"]
        case delta["type"]
        when "text_delta"
          [Event.make(:text_delta, block_id: block[:id], text: delta["text"].to_s)]
        when "thinking_delta"
          [Event.make(:text_delta, block_id: block[:id], text: delta["thinking"].to_s)]
        when "input_json_delta"
          [Event.make(:tool_args_delta, block_id: block[:id], partial_json: delta["partial_json"].to_s)]
        else
          []
        end
      end

      def handle_content_block_stop(event)
        block = @blocks.delete(event["index"])
        return [] unless block
        [Event.make(:block_close, block_id: block[:id])]
      end

      def handle_message_delta(event)
        @deferred_stop_reason = event.dig("delta", "stop_reason")
        @deferred_usage = event["usage"]
        []
      end

      def handle_message_stop(_event)
        events = [Event.make(:message_complete,
          message_id:  @current_message_id,
          stop_reason: Event.normalize_stop_reason(@deferred_stop_reason),
          usage:       @deferred_usage)]
        @deferred_stop_reason = nil
        @deferred_usage = nil
        events
      end

      # ── assistant (non-partial mode only) ─────────────────────────────────────
      # Partial mode: skip (the stream_events already emitted all events for this turn).
      # Non-partial mode: emit the full message lifecycle via the assistant record.

      def handle_assistant(record)
        return [] if @partial_mode

        msg = record["message"]
        return [] unless msg

        message_id = msg["id"]
        events     = [Event.make(:message_start,
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
          when :tool_use
            events << Event.make(:tool_args_delta,
              block_id:     block_id,
              partial_json: JSON.generate(block["input"] || {}))
          when :thinking
            events << Event.make(:text_delta, block_id: block_id, text: block["thinking"].to_s)
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
      # Only tool_result blocks produce events; plain user messages are skipped.

      def handle_user(record)
        msg = record["message"]
        return [] unless msg

        Array(msg["content"])
          .select { |b| b["type"] == "tool_result" }
          .map    { |b| tool_result_event(b) }
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

      # ── result ────────────────────────────────────────────────────────────────

      def handle_result(record)
        [Event.make(:run_complete,
          stop_reason: Event.normalize_stop_reason(record["stop_reason"]),
          duration_ms: record["duration_ms"],
          cost_usd:    record["total_cost_usd"],
          usage:       record["usage"])]
      end
    end
  end
end
