# frozen_string_literal: true

module Space
  module Server
    module Importers
      class Codex
        include Space::Server::Deps["repos.conversations_repo", "repos.messages_repo"]

        STATUS_TO_INT = Space::Server::Relations::Conversations::STATUS_TO_INT

        # Codex wraps every record in {timestamp, type, payload}; Claude transcripts
        # never have a payload envelope.
        def self.matches?(record)
          record.is_a?(Hash) && record.key?("payload")
        end

        def import!(conversation, io)
          conversations_repo.update(conversation.id, status: STATUS_TO_INT[:processing], source: "codex")
          messages_repo.delete_for_conversation(conversation.id)

          @position = 0
          @model    = nil
          @title    = nil
          @session_id   = nil
          @original_cwd = nil
          @agent_version = nil

          io.each_line do |line|
            record = parse(line) or next
            ingest(record, conversation.id)
          end

          conversations_repo.update(conversation.id, {
            status:             STATUS_TO_INT[:completed],
            title:              @title,
            session_id:         conversation.session_id || @session_id,
            parent_session_id:  parent_session_id(conversation),
            original_cwd:       @original_cwd,
            agent_version:      @agent_version
          }.compact)
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

        def parse(line)
          return if line.strip.empty?
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end

        def ingest(record, conversation_id)
          payload = record["payload"] || {}
          case record["type"]
          when "session_meta"
            capture_metadata(payload)
          when "turn_context"
            @model = payload["model"] if payload["model"]
          when "response_item"
            blocks = normalize(payload)
            build_message(payload, blocks, record["timestamp"], conversation_id) if blocks
          end
        end

        def capture_metadata(payload)
          @session_id    ||= payload["id"]
          @original_cwd  ||= payload["cwd"]
          @agent_version ||= payload["cli_version"]
        end

        def normalize(payload)
          case payload["type"]
          when "message"
            normalize_text_message(payload)
          when "reasoning"
            summary = Array(payload["summary"]).filter_map { |s| s.is_a?(Hash) ? s["text"] : s }.join("\n")
            if summary.strip.empty?
              [ { "type" => "redacted_thinking", "data" => payload["encrypted_content"] }.compact ]
            else
              [ { "type" => "thinking", "thinking" => summary, "signature" => payload["encrypted_content"] }.compact ]
            end
          when "function_call"
            [ tool_use(payload, parse_arguments(payload["arguments"])) ]
          when "custom_tool_call"
            key = payload["name"] == "apply_patch" ? "patch" : "input"
            [ tool_use(payload, { key => payload["input"] }) ]
          when "tool_search_call"
            args = payload["arguments"].is_a?(Hash) ? payload["arguments"] : {}
            [ tool_use(payload.merge("name" => "tool_search"), args) ]
          when "web_search_call"
            input = { "query" => payload.dig("action", "query") }.compact
            [ tool_use(payload.merge("name" => "web_search"), input) ]
          when /_output\z/
            [ { "type" => "tool_result", "tool_use_id" => payload["call_id"], "content" => payload["output"].to_s } ]
          end
        end

        def normalize_text_message(payload)
          return nil if payload["role"] == "developer"

          text = Array(payload["content"]).filter_map { |part| part["text"] if part.is_a?(Hash) }.join("\n")
          return nil if text.lstrip.start_with?("<environment_context>")

          @title ||= derive_title(text) if payload["role"] == "user" && prompt_text?(text)
          [ { "type" => "text", "text" => text } ]
        end

        def tool_use(payload, input)
          {
            "type"  => "tool_use",
            "id"    => payload["call_id"] || "call-#{@position}",
            "name"  => payload["name"],
            "input" => input
          }
        end

        def parse_arguments(arguments)
          parsed = JSON.parse(arguments.to_s)
          parsed.is_a?(Hash) ? parsed : { "raw" => arguments }
        rescue JSON::ParserError
          { "raw" => arguments.to_s }
        end

        def prompt_text?(text)
          !text.lstrip.start_with?("<")
        end

        def derive_title(text)
          line = text.lines.map(&:strip).reject { |l| l.nil? || l.empty? }.first
          return nil unless line
          line.length > 80 ? line[0, 80] : line
        end

        def build_message(payload, blocks, timestamp, conversation_id)
          role = payload["role"] || role_for(payload["type"])
          messages_repo.create(
            uuid:            "codex-#{@position}",
            role:            role,
            model:           (@model if role == "assistant"),
            occurred_at:     timestamp,
            position:        @position,
            content:         NulScrub.scrub_nul(blocks),
            conversation_id: conversation_id,
            created_at:      Time.now,
            updated_at:      Time.now
          )
          @position += 1
        end

        def role_for(type)
          type.to_s.end_with?("_output") ? "user" : "assistant"
        end
      end
    end
  end
end
