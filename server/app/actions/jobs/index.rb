# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Jobs
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.jobs_repo"]

          def handle(req, res)
            user = require_login(req, res)

            job_list = jobs_repo.list_for_user(user.id).map do |job|
              {
                id: job.id,
                status: job.status,
                model: job.spec.dig("harness", "model"),
                created_at: job.created_at.iso8601,
                run_id: job.run_id
              }
            end
            render_inertia(req, res, "Jobs/Index", props: { jobs: job_list })
          end
        end
      end
    end
  end
end
