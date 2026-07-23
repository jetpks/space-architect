# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Conversations
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.conversations_repo"]

          def handle(req, res)
            user = current_user(req)
            page = clamped_page(req)
            paged = conversations_repo.visible_to(user, page: page)
            conversation_list = paged[:rows].map do |conv|
              Serializers::Conversation.conversation_list_json(conv, viewer: user)
            end
            render_inertia(req, res, "Conversations/Index", props: {
              conversations: conversation_list,
              pagination: { page: page, has_more: paged[:has_more] }
            })
          end

          private

          def clamped_page(req)
            page = req.params[:page].to_i
            page.positive? ? page : 1
          end
        end
      end
    end
  end
end
