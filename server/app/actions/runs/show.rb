# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Runs
        class Show < Space::Server::Action
          include Space::Server::Deps["repos.runs_repo"]

          def handle(req, res)
            id = req.params[:id].to_i
            run = runs_repo.for_show(id)
            halt_not_found(res) unless run

            user = current_user(req)

            unless run.visible_to?(user)
              alert = user ? "Not found." : "Please sign in to view this run."
              redirect_with_flash(res, "/", alert: alert)
            end

            render_inertia(req, res, "Runs/Show", props: {
              run: {
                id: run.id,
                status: run.status,
                published: run.published
              }
            })
          end
        end
      end
    end
  end
end
