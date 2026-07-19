# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Jobs
        class Cancel < Space::Server::Action
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

            unless jobs_repo.cancel(job.id)
              res.content_type = JSON_CONTENT_TYPE
              halt 409, JSON.generate(error: "Job already #{jobs_repo.by_pk(job.id).status}.")
            end

            render_json(res, { id: job.id, status: "canceled" })
          end

          # require_owner (app/action.rb) carries the same owner semantics as the
          # bearer path — see Jobs::Show's handle_browser.
          def handle_browser(req, res, job)
            require_owner(req, res, job)

            if jobs_repo.cancel(job.id)
              redirect_back_with_flash(req, res, fallback: "/jobs/#{job.id}", notice: "Job canceled.")
            else
              redirect_back_with_flash(req, res, fallback: "/jobs/#{job.id}",
                alert: "Job already #{jobs_repo.by_pk(job.id).status}.")
            end
          end

          def verify_csrf_token?(req, *)
            bearer_request?(req) ? false : super
          end
        end
      end
    end
  end
end
