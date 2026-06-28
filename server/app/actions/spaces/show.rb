# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Spaces
        class Show < Space::Server::Action
          include Space::Server::Deps[
            "repos.spaces_repo",
            "repos.iterations_repo",
            "repos.artifacts_repo",
            "repos.runs_repo"
          ]

          def handle(req, res)
            id    = req.params[:id].to_i
            space = spaces_repo.by_pk(id)
            halt_not_found(res) unless space

            user = current_user(req)
            unless space.visible_to?(user)
              alert = user ? "Not found." : "Please sign in to view this space."
              redirect_with_flash(res, "/", alert: alert)
            end

            iterations = iterations_repo.for_space(space.id)
            artifacts  = artifacts_repo.for_space(space.id)
            runs       = runs_repo.for_space(space.id)

            iter_artifacts = artifacts.group_by(&:iteration_id)
            iter_runs      = runs.select { |r| r.iteration_id }.group_by(&:iteration_id)

            iterations_props = iterations.map do |iter|
              {
                id:         iter.id,
                ordinal:    iter.ordinal,
                name:       iter.name,
                freeze_sha: iter.freeze_sha,
                verdict:    iter.verdict,
                artifacts:  Array(iter_artifacts[iter.id]).map { |a| artifact_props(a) },
                runs:       Array(iter_runs[iter.id]).map { |r| run_props(r) }
              }
            end

            unassigned_runs = runs.select { |r| r.iteration_id.nil? }.map { |r| run_props(r) }
            other_artifacts = artifacts.select { |a| a.iteration_id.nil? }
                                       .map { |a| artifact_props(a) }

            render_inertia(req, res, "Spaces/Show", props: {
              space: {
                id:     space.id,
                slug:   space.slug,
                title:  space.title,
                status: space.status.to_s,
                repos:  Array(space.repos)
              },
              iterations:      iterations_props,
              unassigned_runs: unassigned_runs,
              other_artifacts: other_artifacts
            })
          end

          private

          def artifact_props(a)
            { id: a.id, kind: a.kind, path: a.path, title: a.title }
          end

          def run_props(r)
            { id: r.id, lane: r.lane, role: r.role, status: r.status.to_s, conversation_id: r.conversation_id }
          end
        end
      end
    end
  end
end
