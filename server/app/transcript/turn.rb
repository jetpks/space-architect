# frozen_string_literal: true

module Architect
  module Transcript
    # A derived grouping of messages — the unit the UI organizes around. One *prompt*
    # (a human/user message that isn't tool-call machinery) followed by every message
    # the agent produced in response, until the next prompt. Messages before the
    # first prompt form a prompt-less preamble turn, so the grouping stays faithful
    # to the raw stream.
    #
    # Not persisted: a Turn is a pure function of the ordered message list, so there
    # is no second copy of the archive to drift. Identity is the anchor message's id
    # (the prompt, or the first member for a preamble), which makes a turn
    # addressable and annotatable without a table of its own.
    class Turn
      SUMMARY_PREAMBLE = "This session is being continued from a previous conversation that ran out of context"

      attr_reader :messages

      def self.group(messages)
        turns = []
        messages.each_with_index do |message, i|
          nxt = messages[i + 1]
          prev = i.positive? ? messages[i - 1] : nil
          turns << new if starts_turn?(message, prev, nxt, first: turns.empty?)
          turns.last.messages << message
        end
        turns
      end

      # A prompt is a human-initiated user message: not an assistant turn, not a turn
      # made entirely of tool_results, not the stdout half of a slash-command pair
      # (<local-command-stdout> with no <command-name> is machinery, not a prompt),
      # and not an interrupt marker (the record that a human *stopped* the agent, not
      # one they typed — it closes the turn it interrupted, see interrupt?).
      def self.prompt?(message)
        return false unless message.role == "user"
        blocks = message.blocks
        return false if blocks.empty?
        return false if blocks.all? { |b| b["type"] == "tool_result" }
        return false if interrupt?(message)

        text = blocks.filter_map { |b| b["text"] if b["type"] == "text" }.join("\n")
        !(text.include?("<local-command-stdout>") && !text.include?("<command-name>"))
      end

      # The control marker Claude Code injects when a human interrupts the agent (Esc)
      # — `[Request interrupted by user]`, or the `… for tool use]` variant. Codex
      # records the same event as a `<turn_aborted>` envelope. Machinery either way,
      # so it never anchors a turn; it falls into the turn it interrupted as its last
      # message (the client renders it as that turn's terminal).
      def self.interrupt?(message)
        text = message.blocks.filter_map { |b| b["text"] if b["type"] == "text" }.join("\n").lstrip
        text.start_with?("[Request interrupted by user", "<turn_aborted>")
      end

      # When this message opens a turn. A prompt normally does — except a /compact
      # command joins the turn opened by its preceding summary (below). The injected
      # continuation summary opens that turn in the command's place: it precedes the
      # command in the stream (the model reads the summary, then the /compact marker),
      # so the turn starts there even though the summary itself isn't the prompt.
      def self.starts_turn?(message, prev, nxt, first:)
        return true if first
        return true if compact_summary?(message, nxt)
        return false unless prompt?(message)

        !(compact_command?(message) && compact_summary?(prev, message))
      end

      # The user-typed /compact command — the envelope opens the message (mirrors the
      # strict client-side parseCommand) and names compact.
      def self.compact_command?(message)
        return false unless message&.role == "user"
        text = message.blocks.filter_map { |b| b["text"] if b["type"] == "text" }.join("\n")
        text.lstrip.start_with?("<command-name>") && text.match?(%r{<command-name>\s*/?compact\b})
      end

      # The continuation summary Claude Code injects right *before* a /compact: a
      # user-role, text-only message with the known preamble, immediately followed by
      # the command. It's the artifact of compaction (machinery), not a human prompt,
      # so it never anchors its own giant turn — the text check keeps a real message a
      # human happened to send right before /compact from being mistaken for it.
      def self.compact_summary?(message, nxt)
        return false unless message&.role == "user"
        blocks = message.blocks
        return false unless blocks.any? && blocks.all? { |b| b["type"] == "text" }

        text = blocks.filter_map { |b| b["text"] }.join("\n")
        text.lstrip.start_with?(SUMMARY_PREAMBLE) && compact_command?(nxt)
      end

      def initialize
        @messages = []
      end

      # Identity is the prompt when there is one (so a /compact turn is identified by
      # the command, not the giant summary that physically opens it), else the first
      # member (a preamble). For every ordinary turn the prompt *is* the first member,
      # so this is unchanged from "the anchor is the first message".
      def anchor
        prompt || messages.first
      end

      def anchor_id
        anchor&.id
      end

      # The human message that defines this turn, or nil for a preamble turn. Skips an
      # injected compaction summary so the /compact command — not the summary — is the
      # prompt, even though the summary comes first in the stream.
      def prompt
        messages.each_with_index do |message, i|
          next if self.class.compact_summary?(message, messages[i + 1])
          return message if self.class.prompt?(message)
        end
        nil
      end

      # The turn's non-prompt members partitioned into rounds of thought.
      def rounds
        @rounds ||= Round.group(self)
      end
    end
  end
end
