# frozen_string_literal: true

require_relative "normalizer/event"
require_relative "normalizer/claude_code"
require_relative "normalizer/opencode"
require_relative "normalizer/claude_session"
require_relative "normalizer/pi"

module Space
  module Server
    module Normalizer
      # Detect the producer given a pre-parsed first-line record; returns the parser class.
      # Pure classification — no I/O, no instantiation.
      #
      # opencode lines have a "part" key and use "sessionID" (uppercase D).
      # Session-log lines use "sessionId" (camelCase, no underscore).
      # pi's --mode json first line is {"type":"session",...,"version":N,...} — no
      # session_id/sessionId/sessionID/part key, so "version" is the clean tell.
      # Claude Code dispatch lines use "session_id" (snake_case) and have no "part" key.
      def self.select(record)
        return Opencode      if record.key?("part") || record.key?("sessionID")
        return ClaudeSession if record.key?("sessionId")
        return Pi            if record["type"] == "session" && record.key?("version")
        ClaudeCode
      end
    end
  end
end
