# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        class Transcript < Space::Server::Action
          include Space::Server::Deps[
            "repos.spaces_repo",
            "repos.runs_repo",
            "repos.conversations_repo"
          ]

          def handle(req, res)
            space_id = req.params[:id].to_i
            run_id   = req.params[:run_id].to_i

            space = spaces_repo.by_pk(space_id)
            halt_not_found(res) unless space

            user = current_user(req)
            unless space.visible_to?(user)
              alert = user ? "Not found." : "Please sign in to view this space."
              redirect_with_flash(res, "/", alert: alert)
            end

            run = runs_repo.by_pk(run_id)
            halt_not_found(res) unless run && run.space_id == space_id

            unless run.visible_to?(user)
              alert = user ? "Not found." : "Please sign in to view this run."
              redirect_with_flash(res, "/", alert: alert)
            end

            owner        = run.owned_by?(user)
            conversation = run.conversation_id &&
                           conversations_repo.with_messages(run.conversation_id)

            render_json(res, { turns: Serializers::Conversation.turns_for(conversation, owner: owner) })
          end
        end
      end
    end
  end
end
