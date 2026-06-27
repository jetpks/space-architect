# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Conversations
        class Publish < Space::Server::Action
          include Space::Server::Deps["repos.conversations_repo"]

          def handle(req, res)
            id = req.params[:id].to_i
            conversation = conversations_repo.by_pk(id)
            halt_not_found(res) unless conversation

            require_owner(req, res, conversation)

            new_published = !conversation.published?
            conversations_repo.update(id, published: new_published, updated_at: Time.now)
            redirect_with_flash(res, "/conversations/#{id}",
              notice: "Conversation #{new_published ? "published" : "unpublished"}.")
          end
        end
      end
    end
  end
end
