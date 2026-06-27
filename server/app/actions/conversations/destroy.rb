# frozen_string_literal: true

module Architect
  module Actions
    module Conversations
      class Destroy < Architect::Action
        include Architect::Deps["repos.conversations_repo"]

        def handle(req, res)
          id = req.params[:id].to_i
          conversation = conversations_repo.by_pk(id)
          halt_not_found(res) unless conversation

          require_owner(req, res, conversation)

          conversations_repo.delete(id)
          redirect_with_flash(res, "/", notice: "Conversation deleted.")
        end
      end
    end
  end
end
