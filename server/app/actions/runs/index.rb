# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Runs
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.runs_repo"]

          def handle(req, res)
            user = current_user(req)
            run_list = runs_repo.list_visible_to(user).map do |run|
              {
                id: run.id,
                status: run.status,
                published: run.published,
                created_at: run.created_at.iso8601
              }
            end
            render_inertia(req, res, "Runs/Index", props: { runs: run_list })
          end
        end
      end
    end
  end
end
