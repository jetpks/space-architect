# frozen_string_literal: true

require "json"
require_relative "event"

module Architect
  module Normalizer
    # Stateful parser for opencode JSON-line output.
    # Each line is a complete part — no streaming deltas — so events are emitted immediately.
    class Opencode
      def initialize
        @current_message_id = nil
        @block_index = 0
      end

      # Accepts a raw JSON String or a pre-parsed Hash.
      # Empty/blank strings and unparseable JSON return [] without raising.
      def process(line)
        record = line.is_a?(Hash) ? line : parse_json(line)
        return [] unless record

        part = record["part"]
        return [] unless part

        case record["type"]
        when "step_start"  then handle_step_start(part)
        when "text"        then handle_text(part)
        when "reasoning"   then handle_reasoning(part)
        when "tool_use"    then handle_tool_use(part)
        when "step_finish" then handle_step_finish(part)
        else []
        end
      end

      private

      def parse_json(str)
        return nil if str.nil? || str.to_s.strip.empty?
        JSON.parse(str.strip)
      rescue JSON::ParserError
        nil
      end

      def handle_step_start(part)
        @current_message_id = part["messageID"]
        @block_index = 0
        [Event.make(:message_start,
          message_id: @current_message_id,
          model:      nil,
          role:       "assistant",
          usage:      nil)]
      end

      def handle_text(part)
        block_id = part["id"]
        idx      = next_index
        [
          Event.make(:block_open, block_id: block_id, index: idx, block_type: :text, name: nil, tool_use_id: nil),
          Event.make(:text_delta, block_id: block_id, text: part["text"].to_s),
          Event.make(:block_close, block_id: block_id)
        ]
      end

      def handle_reasoning(part)
        block_id = part["id"]
        idx      = next_index
        [
          Event.make(:block_open, block_id: block_id, index: idx, block_type: :thinking, name: nil, tool_use_id: nil),
          Event.make(:text_delta, block_id: block_id, text: part["text"].to_s),
          Event.make(:block_close, block_id: block_id)
        ]
      end

      def handle_tool_use(part)
        block_id = part["id"]
        idx      = next_index
        call_id  = part["callID"]
        state    = part["state"] || {}

        [
          Event.make(:block_open,
            block_id:    block_id,
            index:       idx,
            block_type:  :tool_use,
            name:        part["tool"],
            tool_use_id: call_id),
          Event.make(:tool_args_delta,
            block_id:     block_id,
            partial_json: JSON.generate(state["input"] || {})),
          Event.make(:block_close, block_id: block_id),
          Event.make(:tool_result,
            tool_use_id: call_id,
            content:     state["output"].to_s,
            is_error:    state["status"] == "error")
        ]
      end

      def handle_step_finish(part)
        [Event.make(:message_complete,
          message_id:  @current_message_id,
          stop_reason: Event.normalize_stop_reason(part["reason"]),
          usage:       part["tokens"])]
      end

      def next_index
        @block_index.tap { @block_index += 1 }
      end
    end
  end
end
