# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Jobs
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.jobs_repo"]

          def handle(req, res)
            if bearer_request?(req)
              handle_bearer(req, res)
            else
              handle_browser(req, res)
            end
          end

          private

          def handle_bearer(req, res)
            user = authenticated_user(req)
            unless user
              res.content_type = JSON_CONTENT_TYPE
              halt 401, JSON.generate(error: "Sign in required.")
            end

            render_json(res, { jobs: job_list(user) })
          end

          def handle_browser(req, res)
            user = require_login(req, res)
            render_inertia(req, res, "Jobs/Index", props: { jobs: job_list(user) })
          end

          def job_list(user)
            jobs_repo.list_for_user(user.id).map do |job|
              {
                id: job.id,
                status: job.status,
                model: job.spec.dig("harness", "model"),
                created_at: job.created_at.iso8601,
                run_id: job.run_id
              }
            end
          end
        end
      end
    end
  end
end
