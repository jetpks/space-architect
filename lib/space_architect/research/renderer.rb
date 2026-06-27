# frozen_string_literal: true

module Space::Architect
  module Research
    # Pure, testable verbosity-gated renderer for stream-json events.
    #
    # Levels (§5.3 ladder):
    #   0 (quiet)  — nothing
    #   1 (default) — lifecycle + terminal line only
    #   2 (-v)     — + assistant text
    #   3 (-vv)    — + tool-call names
    #   4 (-vvv)   — + tool-call inputs and results
    #
    # --thinking: + assistant thinking blocks (any level > 0)
    # --jsonl:    emit raw lane-tagged jsonl instead of human text
    class Renderer
      def initialize(level:, thinking: false, jsonl: false)
        @level    = level
        @thinking = thinking
        @jsonl    = jsonl
      end

      # Render a batch of events for a lane.
      # alive: true  → lane still in flight (lifecycle prefix)
      # alive: false → lane finished (terminal line included)
      # Returns a String (may be empty).
      def render(lane:, events:, alive:)
        return "" if @level == 0 && !@jsonl

        if @jsonl
          return events.map { |ev| "[#{lane}] #{JSON.generate(ev)}" }.join("\n").then { |s| s.empty? ? s : "#{s}\n" }
        end

        lines = []
        terminal = nil

        events.each do |ev|
          case ev["type"]
          when "assistant"
            Array(ev.dig("message", "content")).each do |block|
              case block["type"]
              when "thinking"
                lines << "[#{lane}] #{block['thinking'].to_s.strip}" if @thinking && @level >= 1
              when "text"
                lines << "[#{lane}] #{block['text'].to_s.strip}" if @level >= 2
              when "tool_use"
                if @level >= 3
                  name_line = "[#{lane}] tool: #{block['name']}"
                  if @level >= 4
                    input = block["input"]
                    name_line += " #{JSON.generate(input)}" if input && !input.empty?
                  end
                  lines << name_line
                end
              end
            end
          when "user"
            Array(ev.dig("message", "content")).each do |block|
              next unless block["type"] == "tool_result"
              next unless @level >= 4

              content = block["content"]
              lines << "[#{lane}] tool_result: #{content.to_s.strip}"
            end
          when "result"
            terminal = ev
          end
        end

        if terminal
          lines << terminal_line(lane, terminal)
        elsif alive && @level >= 1 && events.empty?
          lines << "[#{lane}] running"
        end

        lines.reject(&:empty?).join("\n").then { |s| s.empty? ? s : "#{s}\n" }
      end

      def lifecycle?
        @level >= 1 && !@jsonl
      end

      private

      def terminal_line(lane, ev)
        if ev["is_error"]
          reason = ev["result"].to_s.strip
          reason = ev["subtype"] if reason.empty?
          "[#{lane}] ✗ failed #{reason}"
        elsif ev["subtype"] == "success"
          dur   = ev["duration_ms"] ? "#{(ev['duration_ms'] / 1000.0).round(1)}s" : "-"
          turns = ev["num_turns"] || "-"
          result_snip = ev["result"].to_s.strip.slice(0, 80)
          "[#{lane}] ✓ complete · STATUS: #{result_snip} · #{dur} · #{turns} turns"
        else
          "[#{lane}] ⚠ nonzero exit"
        end
      end
    end
  end
end
