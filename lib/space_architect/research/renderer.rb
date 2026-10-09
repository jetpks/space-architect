# frozen_string_literal: true

require "json"

module Space::Architect
  module Research
    # Pure, testable verbosity-gated renderer for pi JSONL events.
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
      # alive: false → lane finished
      # Returns a String (may be empty). Terminal lines come from #terminal.
      def render(lane:, events:, alive:)
        return "" if @level == 0 && !@jsonl

        if @jsonl
          return events.map { |ev| "[#{lane}] #{JSON.generate(ev)}" }.join("\n").then { |s| s.empty? ? s : "#{s}\n" }
        end

        lines = []
        events.each do |ev|
          case ev["type"]
          when "message_end"
            next unless ev.dig("message", "role") == "assistant"
            Array(ev.dig("message", "content")).each do |block|
              case block["type"]
              when "thinking"
                lines << "[#{lane}] #{block['thinking'].to_s.strip}" if @thinking && @level >= 1
              when "text"
                lines << "[#{lane}] #{block['text'].to_s.strip}" if @level >= 2
              when "toolCall"
                if @level >= 3
                  name_line = "[#{lane}] tool: #{block['name']}"
                  if @level >= 4
                    arguments = block["arguments"]
                    name_line += " #{JSON.generate(arguments)}" if arguments && !arguments.empty?
                  end
                  lines << name_line
                end
              end
            end
          when "tool_execution_start"
            if @level >= 3
              line = "[#{lane}] tool: #{ev['toolName']}"
              if @level >= 4
                args = ev["args"]
                line += " #{JSON.generate(args)}" if args && !args.empty?
              end
              lines << line
            end
          when "tool_execution_end"
            if @level >= 4
              text = Array(ev.dig("result", "content")).select { |c| c.is_a?(Hash) && c["type"] == "text" }
                                                     .map { |c| c["text"].to_s }.join
              lines << "[#{lane}] tool_result: #{text.strip}"
            end
          end
        end

        lines << "[#{lane}] running" if alive && @level >= 1 && events.empty?

        lines.reject(&:empty?).join("\n").then { |s| s.empty? ? s : "#{s}\n" }
      end

      # The terminal line, fed terminal FACTS by the mux (never a fabricated
      # event): ok/failed, the failure reason or the final-text snippet, the
      # run span, and the turn count.
      def terminal(lane:, ok:, reason: nil, snippet: nil, duration: nil, turns: nil)
        return "" if @level == 0 || @jsonl

        line = if ok
          span  = duration ? "#{duration}s" : "-"
          "[#{lane}] ✓ complete · STATUS: #{snippet.to_s.strip.slice(0, 80)} · #{span} · #{turns || '-'} turns"
        else
          "[#{lane}] ✗ failed #{reason.to_s.strip}"
        end
        "#{line}\n"
      end

      def lifecycle?
        @level >= 1 && !@jsonl
      end
    end
  end
end
