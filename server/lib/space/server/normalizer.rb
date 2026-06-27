# frozen_string_literal: true

require_relative "normalizer/event"
require_relative "normalizer/claude_code"
require_relative "normalizer/opencode"

module Space
  module Server
    module Normalizer
      # Detect the producer given a pre-parsed first-line record; returns the parser class.
      # Pure classification — no I/O, no instantiation.
      #
      # opencode lines have a "part" key and use "sessionID" (uppercase D).
      # Claude Code lines use "session_id" (lowercase d) and have no "part" key.
      def self.select(record)
        return Opencode if record.key?("part") || record.key?("sessionID")
        ClaudeCode
      end
    end
  end
end
