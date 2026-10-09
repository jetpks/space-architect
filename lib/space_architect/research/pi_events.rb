# frozen_string_literal: true

require "time"

module Space::Architect
  module Research
    # Pure helpers over pi's JSONL event stream — parsed event hashes in, values
    # out, no I/O. The one home for the pi-shape predicates: Mux, report
    # extraction, and Supervisor#classify all consume these, so the terminal
    # classification is not duplicated per call site.
    module PiEvents
      # pi's StopReason values that mean the assistant did not finish normally.
      FAILED_STOP_REASONS = %w[error aborted].freeze

      module_function

      # Assistant `message_end` messages, in stream order — the sole source of
      # complete message content (`message_start`/`message_update` are inert;
      # `turn_end`/`agent_end` only replay).
      def assistant_messages(events)
        events.filter_map do |e|
          next unless e.is_a?(Hash) && e["type"] == "message_end" &&
                      e["message"].is_a?(Hash) && e["message"]["role"] == "assistant"
          e["message"]
        end
      end

      def last_assistant_message(events)
        assistant_messages(events).last
      end

      # The last assistant message's stopReason ("stop"/"error"/"aborted"), or
      # nil when the stream has no assistant message_end.
      def stop_reason(events)
        last_assistant_message(events)&.fetch("stopReason", nil)
      end

      def failed_stop_reason?(reason)
        FAILED_STOP_REASONS.include?(reason)
      end

      # Joined text blocks of a message — the report source.
      def message_text(message)
        return "" unless message.is_a?(Hash)
        Array(message["content"]).select { |b| b.is_a?(Hash) && b["type"] == "text" }
                                 .map { |b| b["text"].to_s }
                                 .join
      end

      # Run span in whole-tenths of a second: last assistant message_end
      # `.timestamp` (epoch ms) minus `session.timestamp` (ISO 8601). NOT a sum
      # of per-response durationMs — that omits tool time between turns.
      def duration_seconds(events)
        session = events.find { |e| e.is_a?(Hash) && e["type"] == "session" }
        end_ms  = last_assistant_message(events)&.fetch("timestamp", nil)
        return nil unless session.is_a?(Hash) && session["timestamp"].is_a?(String) && end_ms.is_a?(Numeric)

        start_s = Time.iso8601(session["timestamp"]).to_f
        ((end_ms / 1000.0) - start_s).round(1)
      rescue ArgumentError
        nil
      end

      # One turn_end per turn.
      def turn_count(events)
        events.count { |e| e.is_a?(Hash) && e["type"] == "turn_end" }
      end
    end
  end
end
