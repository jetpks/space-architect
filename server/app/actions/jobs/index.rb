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

            render_json(res, { jobs: job_entries(jobs_repo.list_for_user(user.id)) })
          end

          def handle_browser(req, res)
            user = require_login(req, res)
            page = clamped_page(req)
            paged = jobs_repo.list_for_user_page(user.id, page: page)
            render_inertia(req, res, "Jobs/Index", props: {
              jobs: job_entries(paged[:rows]),
              pagination: { page: page, has_more: paged[:has_more] }
            })
          end

          def clamped_page(req)
            page = req.params[:page].to_i
            page.positive? ? page : 1
          end

          def job_entries(jobs)
            jobs.map do |job|
              entry = {
                id: job.id,
                status: job.status,
                model: job.spec.dig("harness", "model"),
                harness: job.spec.dig("harness", "type"),
                prompt_snippet: Serializers::PromptSnippet.call(job.spec["prompt"]),
                created_at: job.created_at.iso8601,
                run_id: job.run_id
              }
              provenance = job.spec["provenance"]
              provenance ? entry.merge(provenance: provenance) : entry
            end
          end
        end
      end
    end
  end
end
