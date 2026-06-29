# frozen_string_literal: true

require "open3"
require "json"

module Space
  module Server
    # Read-only access to the opencode SQLite database.
    # Shells out to the host sqlite3 CLI via Open3 with ARGV arrays (no shell interpolation).
    class OpencodeStore
      def initialize(db_path)
        @db_path = db_path.to_s
      end

      def available?
        File.exist?(@db_path)
      end

      # Returns sessions whose directory == the argument, ordered by (time_created, id).
      # Ruby-side filtering: injection-safe even when directory contains single quotes.
      def sessions_for(directory)
        return [] unless available?
        rows = query("SELECT id, agent, model, time_created, directory FROM session ORDER BY time_created, id")
        rows.select { |r| r["directory"] == directory }.map do |r|
          r.merge("model" => parse_json(r["model"]))
        end
      rescue StandardError
        []
      end

      # Returns messages for a session ordered by (time_created, id), each with ordered parts.
      # session_id is an alphanumeric ses_* token from our own prior query.
      def messages_for(session_id)
        return [] unless available?

        sid = sql_escape(session_id.to_s)
        msg_rows  = query("SELECT id, time_created, data FROM message WHERE session_id = '#{sid}' ORDER BY time_created, id")
        part_rows = query("SELECT message_id, time_created, data FROM part WHERE session_id = '#{sid}' ORDER BY time_created, id")

        parts_by_msg = part_rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |p, h|
          part_data = parse_json(p["data"])
          h[p["message_id"]] << part_data if part_data
        end

        msg_rows.filter_map do |m|
          data = parse_json(m["data"])
          next unless data
          { "id" => m["id"], "data" => data, "parts" => parts_by_msg[m["id"]] }
        end
      rescue StandardError
        []
      end

      private

      def query(sql)
        out, status = Open3.capture2("sqlite3", "-json", "-readonly", @db_path, sql)
        return [] unless status.success?
        return [] if out.strip.empty?
        JSON.parse(out)
      rescue JSON::ParserError, StandardError
        []
      end

      def parse_json(str)
        return nil unless str.is_a?(String) && !str.strip.empty?
        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def sql_escape(str)
        str.gsub("'", "''")
      end
    end
  end
end
