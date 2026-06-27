# frozen_string_literal: true

module Architect
  module Serializers
    # Pure module functions: every method takes (record, viewer: <User struct or nil>)
    # and returns a plain Hash. No DB calls, no ROM coupling, no global state.
    #
    # PHASE-0 gap: Architect::Structs::Conversation is missing #display_title
    # (it was deferred out of 1c scope). The oracle defines it as
    # `title.presence || "Untitled conversation"`. We inline that logic here via
    # the private #display_title helper until the struct is updated.
    module Conversation
      module_function

      def conversation_list_json(conversation, viewer:, turns_count:)
        owned = conversation.owned_by?(viewer)
        {
          id: conversation.id,
          title: display_title(conversation),
          status: conversation.status,
          published: conversation.published,
          turns_count: turns_count,
          owned: owned,
          shared: !owned && conversation.shared_with?(viewer, access: :view)
        }
      end

      def conversation_json(conversation, viewer:, owner:)
        {
          id: conversation.id,
          title: display_title(conversation),
          status: conversation.status,
          published: conversation.published,
          source: conversation.source,
          original_cwd: conversation.original_cwd,
          git_branch: conversation.git_branch,
          agent_version: conversation.agent_version,
          can_manage: owner,
          can_note: conversation.annotatable_by?(viewer),
          owner: {
            username: conversation.user.username,
            name: conversation.user.name,
            avatar_url: conversation.user.avatar_url
          }
        }
      end

      def share_json(share)
        {
          id: share.id,
          grantee_kind: share.grantee_kind,
          github_login: share.github_login,
          access: share.access,
          avatar_url: "https://avatars.githubusercontent.com/u/#{share.github_id}"
        }
      end

      def turn_json(turn, owner:)
        prompt = turn.prompt
        {
          anchor_id: turn.anchor_id,
          prompt: prompt && message_json(prompt, owner: owner),
          rounds: turn.rounds.map do |round|
            {
              anchor_id: round.anchor_id,
              messages: round.messages.map { |m| message_json(m, owner: owner) }
            }
          end
        }
      end

      def message_json(message, owner:)
        {
          id: message.id,
          role: message.role,
          model: message.model,
          position: message.position,
          published: message.published,
          blocks: message.blocks,
          can_publish: owner
        }
      end

      def annotation_json(annotation, viewer:)
        {
          id: annotation.id,
          body: annotation.body,
          author: annotation.user.username,
          author_avatar_url: annotation.user.avatar_url,
          can_delete: annotation.user_id == viewer&.id,
          target_kind: annotation.target_kind,
          anchor_message_id: annotation.anchor_message_id,
          tool_use_id: annotation.tool_use_id,
          selector: annotation.selector
        }
      end

      # Inlined fallback for the missing Architect::Structs::Conversation#display_title.
      # Matches oracle: `title.presence || "Untitled conversation"`.
      def display_title(conversation)
        t = conversation.title
        t && !t.strip.empty? ? t : "Untitled conversation"
      end
    end
  end
end
