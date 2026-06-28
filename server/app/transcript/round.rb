# frozen_string_literal: true

module Space
  module Server
    module Transcript
      # A derived sub-grouping of a turn — one iteration of the agentic loop. A round
      # is a (thinking? → narrative) preamble followed by the tool calls it spawned;
      # the next narrative starts the next round.
      #
      # Like Turn, a Round is never persisted: it's a pure function of the turn's
      # member messages, so round identity (the anchor message's id) is stable across
      # requests and never drifts with render-time concerns. That purity is the
      # point — the client used to derive rounds from a *visibility-filtered* list
      # whose filter consulted annotations, so annotating a folded message could
      # shift round boundaries. Here machinery rides along inside whatever round its
      # position falls in instead of being filtered out, leaving the boundaries a
      # function of the transcript alone.
      #
      # A Message is the atomic unit of round membership and is never split across
      # rounds. For builder/claude-code imports, an entire assistant turn is persisted
      # as a single bundled message (blocks: [thinking?, text, tool_use, …]). The
      # round boundary predicate uses leads_with_narrative? to handle both the
      # one-block-per-message (architect) shape and the bundled (builder) shape
      # uniformly: a message that leads with a narrative block opens a new round.
      class Round
        attr_reader :messages

        # Partition the turn's non-prompt members, in order. A new round opens at a
        # structural (non-machinery) message that leads with narrative once the current
        # round holds at least one action; machinery never opens or splits a round.
        # For single-block messages, leads_with_narrative? is equivalent to !action?.
        def self.group(turn)
          prompt_id = turn.prompt&.id
          rounds = []
          has_action = false
          turn.messages.each do |message|
            next if message.id == prompt_id
            action = action?(message)
            if rounds.empty? || (leads_with_narrative?(message) && has_action && !machinery?(message))
              rounds << new
              has_action = false
            end
            rounds.last.messages << message
            has_action ||= action
          end
          rounds
        end

        # A message that performs an action (calls a tool) vs. pure
        # reasoning/narrative.
        def self.action?(message)
          message.blocks.any? { |b| b["type"] == "tool_use" }
        end

        # True iff a narrative block (text, thinking, or redacted_thinking) precedes
        # the message's first tool_use block — or the message has no tool_use at all.
        # For single-block messages this is equivalent to !action?: a lone text/thinking
        # block returns true; a lone tool_use returns false.
        def self.leads_with_narrative?(message)
          narrative_types = %w[text thinking redacted_thinking]
          message.blocks.each do |b|
            return true if narrative_types.include?(b["type"])
            return false if b["type"] == "tool_use"
          end
          true
        end

        # Plumbing that rides along without shaping the round structure: tool_result
        # deliveries, the stdout half of a slash-command pair, empty thinking blocks
        # (interleaved-thinking noise — a signature over an empty string, no thought
        # behind it), and the continuation summary injected before /compact. The
        # client folds these into other rows (or hides them), so they must not anchor
        # or split rounds. redacted_thinking is deliberately NOT machinery: a hidden
        # thought is still a thought — it opens and anchors rounds like narrative.
        def self.machinery?(message)
          blocks = message.blocks
          return false if blocks.empty?
          return true if blocks.all? { |b| b["type"] == "tool_result" }
          return true if blocks.all? { |b| b["type"] == "thinking" && b["thinking"].to_s.strip.empty? }

          if message.role == "user"
            text = blocks.filter_map { |b| b["text"] if b["type"] == "text" }.join("\n")
            return true if text.include?("<local-command-stdout>") && !text.include?("<command-name>")
            return true if text.lstrip.start_with?(Turn::SUMMARY_PREAMBLE)
          end
          false
        end

        def initialize
          @messages = []
        end

        # Identity is the first structural member — the same message the client's
        # round-${id} DOM anchors have always used — falling back to the first member
        # for an all-machinery round.
        def anchor
          messages.find { |m| !self.class.machinery?(m) } || messages.first
        end

        def anchor_id
          anchor&.id
        end
      end
    end
  end
end
