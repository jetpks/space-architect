# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Jobs
        class Show < Space::Server::Action
          include Space::Server::Deps["repos.jobs_repo"]

          def handle(req, res)
            job = jobs_repo.by_pk(req.params[:id].to_i)
            halt_not_found(res) unless job

            user = authenticated_user(req)
            unless user
              res.content_type = JSON_CONTENT_TYPE
              halt 401, JSON.generate(error: "Sign in required.")
            end

            unless job.owned_by?(user)
              res.content_type = JSON_CONTENT_TYPE
              halt 403, JSON.generate(error: "Not authorized.")
            end

            render_json(res, {
              id: job.id,
              status: job.status,
              spec: job.spec,
              run_id: job.run_id,
              created_at: job.created_at.iso8601,
              updated_at: job.updated_at.iso8601
            })
          end
        end
      end
    end
  end
end
