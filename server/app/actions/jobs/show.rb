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

            if bearer_request?(req)
              handle_bearer(req, res, job)
            else
              handle_browser(req, res, job)
            end
          end

          private

          # Today's JSON shape and authz, unchanged.
          def handle_bearer(req, res, job)
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

          # require_owner (app/action.rb) carries the same owner semantics as the
          # bearer path — anon redirects home with a sign-in flash, non-owner redirects
          # home with a not-authorized flash — via the Inertia-appropriate mechanism.
          def handle_browser(req, res, job)
            require_owner(req, res, job)

            render_inertia(req, res, "Jobs/Show", props: {
              job: {
                id: job.id,
                status: job.status,
                attempts: job.attempts,
                run_id: job.run_id,
                spec: job.spec,
                created_at: job.created_at.iso8601,
                updated_at: job.updated_at.iso8601
              }
            })
          end
        end
      end
    end
  end
end
