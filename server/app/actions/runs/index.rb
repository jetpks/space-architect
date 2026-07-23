# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Runs
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.runs_repo", "repos.jobs_repo"]

          def handle(req, res)
            user = current_user(req)
            page = clamped_page(req)
            paged = runs_repo.list_visible_to(user, page: page)
            jobs_by_run_id = jobs_repo.by_run_ids(paged[:rows].map(&:id))

            run_list = paged[:rows].map do |run|
              {
                id: run.id,
                status: run.status,
                published: run.published,
                harness: run.harness,
                model: run.model,
                lane: run.lane,
                created_at: run.created_at.iso8601,
                prompt_snippet: prompt_snippet(jobs_by_run_id[run.id], user)
              }
            end
            render_inertia(req, res, "Runs/Index", props: {
              runs: run_list,
              pagination: { page: page, has_more: paged[:has_more] }
            })
          end

          private

          def clamped_page(req)
            page = req.params[:page].to_i
            page.positive? ? page : 1
          end

          # Owner-only, mirroring Runs::Show#job_props — a published run must
          # not leak its originating prompt to anonymous or non-owner viewers.
          def prompt_snippet(job, user)
            return nil unless job&.owned_by?(user)
            Serializers::PromptSnippet.call(job.spec["prompt"])
          end
        end
      end
    end
  end
end
