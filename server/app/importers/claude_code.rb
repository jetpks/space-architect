# frozen_string_literal: true

module Space
  module Server
    module Importers
      class ClaudeCode
        include Space::Server::Deps["repos.conversations_repo", "repos.messages_repo"]

        STATUS_TO_INT = Space::Server::Relations::Conversations::STATUS_TO_INT
        TURN_TYPES    = %w[user assistant].freeze

        def import!(conversation, io)
          conversations_repo.update(conversation.id, status: STATUS_TO_INT[:processing], source: "claude_code")
          messages_repo.delete_for_conversation(conversation.id)

          @title        = nil
          @session_id   = nil
          @original_cwd = nil
          @git_branch   = nil
          @agent_version = nil
          position = 0

          io.each_line do |line|
            record = parse(line) or next

            capture_metadata(record)
            @title = record["aiTitle"] if record["type"] == "ai-title"
            next unless turn?(record)

            build_message(record, position, conversation.id)
            position += 1
          end

          conversations_repo.update(conversation.id, {
            status:             STATUS_TO_INT[:completed],
            title:              @title,
            session_id:         conversation.session_id || @session_id,
            parent_session_id:  parent_session_id(conversation),
            original_cwd:       @original_cwd,
            git_branch:         @git_branch,
            agent_version:      @agent_version
          }.compact)
        rescue => e
          conversations_repo.update(conversation.id, status: STATUS_TO_INT[:failed])
          raise e
        end

        def self.matches?(_record)
          false
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

        def turn?(record)
          TURN_TYPES.include?(record["type"]) && !record["isMeta"]
        end

        def capture_metadata(record)
          @session_id    ||= record["sessionId"]
          @original_cwd  ||= record["cwd"]
          @git_branch    ||= record["gitBranch"]
          @agent_version ||= record["version"]
        end

        def build_message(record, position, conversation_id)
          message = record["message"] || {}
          messages_repo.create(
            uuid:            NulScrub.scrub_nul(record["uuid"]),
            parent_uuid:     NulScrub.scrub_nul(record["parentUuid"]),
            role:            NulScrub.scrub_nul(message["role"] || record["type"]),
            model:           NulScrub.scrub_nul(message["model"]),
            occurred_at:     record["timestamp"],
            position:        position,
            content:         NulScrub.scrub_nul(normalize_content(message["content"])),
            conversation_id: conversation_id,
            created_at:      Time.now,
            updated_at:      Time.now
          )
        end

        def normalize_content(content)
          case content
          when String then [ { "type" => "text", "text" => content } ]
          when Array  then content
          else []
          end
        end
      end
    end
  end
end
