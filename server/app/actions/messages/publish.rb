# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Messages
        class Publish < Space::Server::Action
          include Space::Server::Deps["repos.messages_repo", "repos.conversations_repo"]

          def handle(req, res)
            id = req.params[:id].to_i
            message = messages_repo.by_pk(id)
            halt_not_found(res) unless message

            conversation = conversations_repo.by_pk(message.conversation_id)
            halt_not_found(res) unless conversation

            require_owner(req, res, conversation)

            new_published = !message.published
            messages_repo.update(id, published: new_published, updated_at: Time.now)
            redirect_with_flash(res, "/conversations/#{conversation.id}#message-#{id}",
              notice: "Turn #{new_published ? "published" : "unpublished"}.")
          end
        end
      end
    end
  end
end
