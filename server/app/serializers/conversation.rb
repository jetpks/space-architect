# frozen_string_literal: true

module Space
  module Server
    module Serializers
      # Pure module functions: every method takes (record, viewer: <User struct or nil>)
      # and returns a plain Hash. No DB calls, no ROM coupling, no global state.
      #
      # PHASE-0 gap: Space::Server::Structs::Conversation is missing #display_title
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

        # parent/children default to a sentinel (not nil) so callers that omit them
        # entirely (list views, unit tests fixed to the pre-linkage key set) get no
        # parent/children keys at all; the owner-gated Show action opts in explicitly.
        NOT_PROVIDED = Object.new.freeze
        private_constant :NOT_PROVIDED

        def conversation_json(conversation, viewer:, owner:, parent: NOT_PROVIDED, children: NOT_PROVIDED)
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
          }.tap do |json|
            unless parent.equal?(NOT_PROVIDED)
              json[:parent] = parent && { id: parent.id, title: display_title(parent) }
            end

            unless children.equal?(NOT_PROVIDED)
              json[:children] = children.to_a.map { |c| { id: c.id, title: display_title(c), session_id: c.session_id } }
            end
          end
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

        def turns_for(conversation, owner:)
          return [] unless conversation

          Space::Server::Transcript::Turn.group(conversation.messages).map do |t|
            turn_json(t, owner: owner)
          end
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

        # Inlined fallback for the missing Space::Server::Structs::Conversation#display_title.
        # Matches oracle: `title.presence || "Untitled conversation"`.
        def display_title(conversation)
          t = conversation.title
          t && !t.strip.empty? ? t : "Untitled conversation"
        end
      end
    end
  end
end
