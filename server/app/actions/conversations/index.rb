# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Conversations
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.conversations_repo"]

          def handle(req, res)
            user = current_user(req)
            conversations = conversations_repo.visible_to(user)
            conversation_list = conversations.map do |conv|
              turns_count = Space::Server::Transcript::Turn.group(conv.visible_messages(user)).size
              Serializers::Conversation.conversation_list_json(conv, viewer: user, turns_count: turns_count)
            end
            render_inertia(req, res, "Conversations/Index", props: { conversations: conversation_list })
          end
        end
      end
    end
  end
end
