# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        class Run < Space::Server::Action
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

            owner = run.owned_by?(user)
            turns = build_turns(run, owner)

            render_inertia(req, res, "Spaces/Run", props: {
              space: { id: space.id, slug: space.slug, title: space.title },
              run: {
                id:              run.id,
                lane:            run.lane,
                role:            run.role,
                status:          run.status.to_s,
                producer:        run.producer,
                session_id:      run.session_id,
                iteration_id:    run.iteration_id,
                conversation_id: run.conversation_id
              },
              turns: turns
            })
          end

          private

          def build_turns(run, owner)
            return [] unless run.conversation_id

            conversation = conversations_repo.with_messages(run.conversation_id)
            Serializers::Conversation.turns_for(conversation, owner: owner)
          end
        end
      end
    end
  end
end
