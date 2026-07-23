# frozen_string_literal: true

require "time"
require "json"

module Space
  module Server
    module Importers
      class Pi
        include Space::Server::Deps["repos.conversations_repo", "repos.messages_repo"]

        STATUS_TO_INT = Space::Server::Relations::Conversations::STATUS_TO_INT

        PI_ENTRY_TYPES = %w[message model_change thinking_level_change compaction branch_summary custom custom_message label session_info].freeze
        PI_STREAMING_LIFECYCLE_TYPES = %w[agent_start agent_end turn_start turn_end message_start message_update message_end tool_execution_start tool_execution_update tool_execution_end].freeze

        class PiImportError < StandardError; end

        def self.matches?(record)
          return false unless record.is_a?(Hash)
          return true if record["type"] == "session" && record["version"].is_a?(Integer)
          return false if record.key?("payload") # Codex envelope
          return true if PI_ENTRY_TYPES.include?(record["type"]) && record["id"].is_a?(String) && record.key?("parentId")
          return true if PI_STREAMING_LIFECYCLE_TYPES.include?(record["type"])
          false
        end

        def import!(conversation, io)
          conversations_repo.update(conversation.id, status: STATUS_TO_INT[:processing], source: "pi")
          messages_repo.delete_for_conversation(conversation.id)

          @position     = 0
          @model        = nil
          @title        = nil
          @session_id   = nil
          @original_cwd = nil

          entries = load_entries(io)
          header  = entries.find { |e| e["type"] == "session" }
          capture_metadata(header)

          if tree_format?(entries)
            active_branch(entries).each { |entry| ingest(entry, conversation.id) }
          else
            ingest_stream(entries, conversation.id)
          end

          if messages_repo.for_conversation(conversation.id).empty?
            raise PiImportError, "pi importer produced 0 messages (file recognized as pi but no message_end / tree entries were parseable)"
          end

          conversations_repo.update(conversation.id, {
            status:             STATUS_TO_INT[:completed],
            title:              @title,
            session_id:         conversation.session_id || @session_id,
            original_cwd:       @original_cwd
          }.compact.merge(parent_session_id: parent_session_id(conversation)))
        rescue => e
          conversations_repo.update(conversation.id, status: STATUS_TO_INT[:failed])
          raise e
        end

        private

        def parent_session_id(conversation)
          return nil unless conversation.session_id
          return nil if @session_id.nil? || @session_id == conversation.session_id
          @session_id
        end

        def load_entries(io)
          entries = []
          io.each_line.with_index do |line, index|
            next if line.strip.empty?
            begin
              entries << JSON.parse(line).merge("__index" => index)
            rescue JSON::ParserError
              next
            end
          end
          entries
        end

        def tree_format?(entries)
          entries.any? { |e| e["id"].is_a?(String) && e.key?("parentId") }
        end

        def ingest_stream(entries, conversation_id)
          stream_index = 0
          entries.each do |entry|
            next unless entry["type"] == "message_end"
            message = entry["message"] || {}
            pseudo = {
              "id"        => "pi-#{stream_index}",
              "parentId"  => nil,
              "timestamp" => timestamp_for(message),
              "message"   => message
            }
            stream_index += 1
            ingest_message(pseudo, conversation_id)
          end
        end

        def timestamp_for(message)
          raw = message["timestamp"]
          case raw
          when Integer
            Time.at(raw / 1000.0)
          when String
            begin
              Time.iso8601(raw)
            rescue ArgumentError
              Time.now
            end
          else
            Time.now
          end
        end

        def active_branch(entries)
          by_id = entries.each_with_object({}) do |e, h|
            h[e["id"]] = e if e["id"].is_a?(String) && e.key?("parentId")
          end

          child_ids = entries.filter_map { |e| e["parentId"] }.to_set
          leaf_id = entries.reverse.find { |e| e["id"].is_a?(String) && e.key?("parentId") && !child_ids.include?(e["id"]) }&.dig("id")
          leaf_id ||= entries.reverse.find { |e| e["id"].is_a?(String) && e.key?("parentId") }&.dig("id")

          branch = []
          current = by_id[leaf_id]
          while current
            branch.unshift(current)
            current = by_id[current["parentId"]]
          end
          branch
        end

        def capture_metadata(header)
          return unless header
          @session_id   = header["id"]
          @original_cwd = header["cwd"]
        end

        def ingest(entry, conversation_id)
          case entry["type"]
          when "message"
            ingest_message(entry, conversation_id)
          when "model_change"
            @model = "#{entry["provider"]}/#{entry["modelId"]}" if entry["provider"] && entry["modelId"]
          end
        end

        def ingest_message(entry, conversation_id)
          message = entry["message"] || {}
          role    = message["role"]
          blocks  = blocks_for(message)
          return if blocks.empty?

          @title ||= derive_title(blocks) if role == "user"

          if role == "assistant"
            text_blocks = blocks.select { |b| b["type"] == "text" }
            tool_blocks = blocks.select { |b| b["type"] == "tool_use" }
            create_assistant_message(entry, message, text_blocks, conversation_id) if text_blocks.any?
            tool_blocks.each_with_index do |tool_block, index|
              create_assistant_message(entry, message, [ tool_block ], conversation_id, suffix: tool_blocks.one? ? "-tools" : "-tools-#{index + 1}")
            end
          else
            create_message(entry, message, blocks, conversation_id)
          end
        end

        def blocks_for(message)
          case message["role"]
          when "user"          then normalize_user_content(message["content"])
          when "assistant"     then normalize_assistant_content(message["content"])
          when "toolResult"    then normalize_tool_result(message)
          when "bashExecution" then normalize_bash_execution(message)
          else []
          end
        end

        def map_role(role)
          case role
          when "user", "assistant" then role
          when "toolResult", "bashExecution" then "user"
          else "user"
          end
        end

        def model_for(message)
          return nil unless map_role(message["role"]) == "assistant"
          message["model"] || @model
        end

        def normalize_user_content(content)
          case content
          when String
            [ text_block(content) ]
          when Array
            content.filter_map do |part|
              case part["type"]
              when "text"  then text_block(part["text"])
              when "image" then nil
              end
            end
          else
            []
          end
        end

        def normalize_assistant_content(content)
          return [] unless content.is_a?(Array)
          content.filter_map do |part|
            case part["type"]
            when "text", "thinking" then text_block(part["text"] || part["thinking"])
            when "toolCall"         then normalize_tool_call(part)
            when "image"            then nil
            end
          end
        end

        def normalize_tool_call(part)
          {
            "type"  => "tool_use",
            "id"    => part["id"],
            "name"  => part["name"],
            "input" => part["arguments"] || {}
          }
        end

        def normalize_tool_result(message)
          content = message["content"]
          text = case content
          when String then content
          when Array
            content.filter_map { |part| part["text"] if part.is_a?(Hash) && part["type"] == "text" }.join("\n")
          else
            ""
          end

          [ {
            "type"        => "tool_result",
            "tool_use_id" => message["toolCallId"],
            "content"     => text,
            "is_error"    => message["isError"] || false
          } ]
        end

        def normalize_bash_execution(message)
          command = message["command"]
          output  = message["output"].to_s
          trailer = bash_trailer(message)
          stdout  = trailer.empty? ? output : "#{trailer}\n#{output}"

          text = if command
            [
              "<command-name>bash</command-name>",
              "<command-args>#{command}</command-args>",
              "<local-command-stdout>#{stdout}</local-command-stdout>"
            ].join("\n")
          else
            output
          end

          [ text_block(text) ]
        end

        def bash_trailer(message)
          parts = []
          parts << "exit code: #{message["exitCode"]}" if message["exitCode"] && message["exitCode"] != 0
          parts << "[cancelled]" if message["cancelled"]
          parts << "[truncated]" if message["truncated"]
          parts.join(" ")
        end

        def create_message(entry, message, blocks, conversation_id)
          messages_repo.create(
            uuid:            entry["id"],
            parent_uuid:     entry["parentId"],
            role:            map_role(message["role"]),
            model:           model_for(message),
            occurred_at:     entry["timestamp"],
            position:        @position,
            content:         NulScrub.scrub_nul(blocks),
            conversation_id: conversation_id,
            created_at:      Time.now,
            updated_at:      Time.now
          )
          @position += 1
        end

        def create_assistant_message(entry, message, blocks, conversation_id, suffix: nil)
          return if blocks.empty?

          messages_repo.create(
            uuid:            suffix ? "#{entry["id"]}#{suffix}" : entry["id"],
            parent_uuid:     entry["parentId"],
            role:            "assistant",
            model:           model_for(message),
            occurred_at:     entry["timestamp"],
            position:        @position,
            content:         NulScrub.scrub_nul(blocks),
            conversation_id: conversation_id,
            created_at:      Time.now,
            updated_at:      Time.now
          )
          @position += 1
        end

        def text_block(text)
          { "type" => "text", "text" => text.to_s }
        end

        def derive_title(blocks)
          text = blocks.filter_map { |b| b["text"] if b["type"] == "text" }.join(" ").strip
          return nil if text.empty?

          if text.start_with?("<skill ") && text.include?("</skill>")
            skill_title = skill_envelope_title(text)
            return skill_title if skill_title
          end

          line = text.lines.map(&:strip).reject { |l| l.nil? || l.empty? }.first
          return nil unless line
          line.length > 80 ? line[0, 80] : line
        end

        def skill_envelope_title(text)
          after = text.split("</skill>", 2).last
          line  = after.lines.map(&:strip).reject { |l| l.nil? || l.empty? }.first
          return line.length > 80 ? line[0, 80] : line if line

          name = text[/<skill\s+name="([^"]*)"/, 1]
          "skill: #{name}" if name
        end
      end
    end
  end
end
