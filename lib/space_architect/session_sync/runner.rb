# frozen_string_literal: true

require_relative "cursor"
require_relative "session_id"

module Space::Architect
  module SessionSync
    # One sync pass: scans the pi + claude session roots, decides
    # upload/skip per the frozen cursor rules, uploads via the injected
    # client, and persists the updated cursor (unless dry_run).
    class Runner
      RECENT_MTIME_SECONDS = 60

      def initialize(client:, state_path:, pi_root:, claude_root:, now: -> { Time.now }, dry_run: false)
        @client = client
        @state_path = state_path
        @pi_root = pi_root
        @claude_root = claude_root
        @now = now
        @dry_run = dry_run
      end

      def call
        cursor = Cursor.load(@state_path)
        results = files.map { |path, session_id| process(path, session_id, cursor) }
        Cursor.write(@state_path, cursor) unless @dry_run
        results
      end

      private

      def process(path, session_id, cursor)
        stat = File.stat(path)
        recorded = cursor[path]

        return {path: path, session_id: session_id, action: :skipped, reason: "recent mtime"} if recent_mtime?(stat)
        return {path: path, session_id: session_id, action: :skipped, reason: "unchanged"} if recorded && recorded.size >= stat.size

        return {path: path, session_id: session_id, action: :would_upload} if @dry_run

        response = @client.upload(path: path, session_id: session_id)
        if [200, 201].include?(response[:status])
          cursor[path] = Cursor::Entry.new(size: stat.size, mtime: stat.mtime.to_i)
          {path: path, session_id: session_id, action: response[:status] == 201 ? :uploaded : :updated,
           conversation_id: response[:conversation_id]}
        else
          {path: path, session_id: session_id, action: :failed, status: response[:status], errors: response[:errors]}
        end
      end

      def recent_mtime?(stat)
        (@now.call - stat.mtime) < RECENT_MTIME_SECONDS
      end

      def files
        pi = Dir.glob(File.join(@pi_root, "**", "*.jsonl")).map { |p| [p, SessionId.for_pi(p)] }
        claude = Dir.glob(File.join(@claude_root, "**", "*.jsonl")).map { |p| [p, SessionId.for_claude(p)] }
        pi + claude
      end
    end
  end
end
