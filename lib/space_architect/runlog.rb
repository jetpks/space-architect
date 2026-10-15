# frozen_string_literal: true

require "json"

module Space
  module Architect
    # Pretty-prints a pi agent run.jsonl as it streams — a faithful port of
    # ~/bin/runlog (the byte-compat oracle; same display bytes).
    #
    #   tail -f build/I08-.../run.jsonl | architect runlog
    #   architect runlog build/I08-.../run.jsonl
    #
    # Thinking is dim, assistant text is plain, tool calls and their results are
    # one-liners. System/user/toolResult message echoes, and non-JSON noise on
    # the stream, are dropped.
    #
    # Truncation of tool inputs/outputs defaults to 2000 characters; override
    # with RUNLOG_LIMIT.
    module Runlog
      DEFAULT_LIMIT = 2000

      class << self
        # Iterates input's lines, dropping non-`{`-prefixed lines and JSON parse
        # failures, feeding a Printer. Interrupt → quiet return with the output
        # already on screen (ctrl+c while tail-following a live run).
        def stream(input:, io: $stdout, env: ENV)
          printer = Printer.new(
            io: io,
            limit: (env["RUNLOG_LIMIT"] || DEFAULT_LIMIT).to_i,
            color: io.tty? && env["NO_COLOR"].nil?
          )
          input.each_line do |raw|
            next unless raw.start_with?("{")

            event = JSON.parse(raw) rescue next
            printer.handle(event)
          end
        rescue Interrupt
          nil
        end
      end

      # Ported verbatim from the oracle script: streamed deltas write
      # progressively (label held back until a block actually emits), whole
      # tool events one-line, and usage accumulates across the tool rounds of
      # an exchange so the done line reports the whole turn, not one round.
      class Printer
        def initialize(io:, limit:, color:)
          @io = io
          @limit = limit
          @color = color
          @column = 0     # tracks whether we're mid-line inside a streamed block
          @mode = nil     # :thinking or :text, so we only label a block once
          @label = nil    # header held back until the block actually emits something
          @turn = nil     # usage accumulated across the rounds of the exchange in flight
        end

        def handle(event)
          case event["type"]
          when "message_update"      then delta(event["assistantMessageEvent"], event["usage"])
          when "message_start"       then message_start(event["message"])
          when "message_end"         then message_end(event["message"])
          when "tool_execution_start" then tool_call(event)
          when "tool_execution_end"   then tool_result(event)
          when "turn_end"             then turn_end(event["message"])
          end
        end

        private

        def message_start(message)
          return unless message["role"] == "assistant"

          @column = 0
          @mode = nil
          @label = nil
        end

        def delta(ev, usage)
          case ev["type"]
          when "thinking_start" then start_prose(:thinking, dim("· thinking"))
          when "text_start"     then start_prose(:text, bold("● assistant"))
          when "thinking_delta" then write(dim(ev["delta"]))
          when "text_delta"     then write(ev["delta"])
          when "thinking_end"   then catch_up(:thinking, "· thinking", ev["content"], usage&.dig("reasoning").to_i)
          when "text_end"       then catch_up(:text, "● assistant", ev["content"], nil)
          # toolcall_start/delta/end carry the model's tool arguments, but the
          # harness re-emits the canonical args on tool_execution_start, which is
          # what we display — one source, and it reflects what actually ran.
          end
        end

        # Some models redact their thinking (or stream nothing at all) but still
        # deliver the full block on the *_end event, or at least report a token
        # count in the usage. The label is held back until a delta writes something;
        # if the block ends with the label still pending, nothing was streamed, so
        # show what we have.
        def catch_up(mode, header, content, reasoning)
          return unless @mode == mode && @label

          if content.to_s.empty?
            @label = nil
            line dim("#{header} (#{reasoning} tokens, not streamed)") if reasoning.to_i.positive?
          else
            write(content)
          end
        end

        # "system" / "user" / "toolResult" message echoes carry nothing the
        # deltas and tool_execution_* events don't already show.
        def message_end(message)
          break_line if message["role"] == "assistant"
          start_turn(message) if message["role"] == "user"
        end

        # A user message opens a conversation exchange: every round that follows
        # belongs to it, up through the final assistant reply.
        def start_turn(message)
          @turn = { started_at: message["timestamp"], output: 0, cache_read: 0, cost: 0.0, duration_ms: 0 }
        end

        def tool_call(event)
          break_line
          args = event["args"] || {}
          summary = args.map { |k, v| "#{k}: #{oneline(v)}" }.join("  ")
          line "#{cyan("⚒ #{event["toolName"]}")} #{dim(summary)}"
        end

        def tool_result(event)
          result = event["result"] || {}
          body = flatten(result["content"])
          body = result.dig("structuredContent", "output").to_s if body.empty?
          lines = body.lines
          marker = event["isError"] ? red("✗") : green("←")
          note = lines.size > 1 ? dim(" (#{lines.size} lines)") : ""
          line "#{marker} #{oneline(body)}#{note}"
        end

        def flatten(content)
          case content
          when String then content
          when Array  then content.map { |b| b.is_a?(Hash) ? b["text"].to_s : b.to_s }.join("\n")
          else content.to_s
          end
        end

        # Each API round in the stream is a "turn": turn_end fires whenever the
        # model stops, with stopReason "toolUse" whenever it stopped to run tools.
        # The done line therefore waits for a final stop reason and reports usage
        # summed across the whole exchange — not once per tool round.
        def turn_end(message)
          usage = message["usage"] || {}
          turn = (@turn ||= { started_at: nil, output: 0, cache_read: 0, cost: 0.0, duration_ms: 0 })
          turn[:output] += usage["output"].to_i
          turn[:cache_read] += usage["cacheRead"].to_i
          turn[:cost] += usage.dig("cost", "total").to_f
          turn[:duration_ms] += message["durationMs"].to_i
          return if message["stopReason"] == "toolUse"

          from, to = turn[:started_at], message["timestamp"]
          elapsed = from && to ? to - from : turn[:duration_ms]
          stats = [
            "#{turn[:output]} out",
            "#{turn[:cache_read]} cache read",
            ("$#{format("%.2f", turn[:cost])}" if turn[:cost].positive?),
            "#{elapsed / 1000}s"
          ].compact.join("  ")
          failed = message["stopReason"].to_s.casecmp("error").zero?
          line((failed ? red("✗ failed") : green("✓ done")) + dim("  #{stats}"))
          @turn = nil
        end

        # --- output plumbing ---------------------------------------------------

        def start_prose(mode, label)
          break_line
          @label = label
          @mode = mode
        end

        def write(text)
          return if text.nil? || text.empty?

          if @label
            @io.puts @label
            @label = nil
          end
          @io.write(text)
          @io.flush
          @column += text.length
        end

        def line(text)
          @label = nil
          break_line
          @io.puts text
          @io.flush
        end

        def break_line
          return if @column.zero?

          @io.puts
          @column = 0
          @mode = nil
        end

        # --- paint ---------------------------------------------------------------

        def paint(text, code)
          @color ? "\e[#{code}m#{text}\e[0m" : text
        end

        def dim(s)  = paint(s, "2")
        def bold(s) = paint(s, "1")
        def cyan(s) = paint(s, "36")
        def green(s) = paint(s, "32")
        def red(s)  = paint(s, "31")

        # Collapses whitespace and clips, so a tool argument stays on one line.
        def oneline(value, limit = @limit)
          s = value.to_s.gsub(/\s+/, " ").strip
          s.length > limit ? "#{s[0, limit]}…" : s
        end
      end
    end
  end
end
