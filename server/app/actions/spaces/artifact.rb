# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        class Artifact < Space::Server::Action
          include Space::Server::Deps[
            "repos.spaces_repo",
            "repos.artifacts_repo"
          ]

          def handle(req, res)
            space_id    = req.params[:id].to_i
            artifact_id = req.params[:artifact_id].to_i

            space = spaces_repo.by_pk(space_id)
            halt_not_found(res) unless space

            user = current_user(req)
            unless space.visible_to?(user)
              alert = user ? "Not found." : "Please sign in to view this space."
              redirect_with_flash(res, "/", alert: alert)
            end

            artifact = artifacts_repo.by_pk(artifact_id)
            halt_not_found(res) unless artifact && artifact.space_id == space_id

            render_inertia(req, res, "Spaces/Artifact", props: {
              space:    { id: space.id, slug: space.slug, title: space.title },
              artifact: {
                id:    artifact.id,
                kind:  artifact.kind,
                path:  artifact.path,
                title: artifact.title,
                raw:   artifact.raw
              }
            })
          end
        end
      end
    end
  end
end
