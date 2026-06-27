# frozen_string_literal: true

module Architect
  module Actions
    module Runs
      class Create < Architect::Action
        include Architect::Deps["repos.runs_repo"]

        def handle(req, res)
          user = authenticated_user(req)
          unless user
            res.content_type = JSON_CONTENT_TYPE
            halt 401, JSON.generate(error: "Sign in required.")
          end

          now = Time.now
          run = runs_repo.create(user_id: user.id, status: 0, created_at: now, updated_at: now)

          render_json(res, { id: run.id, status: :pending }, status: 201)
        end

        private

        def verify_csrf_token?(req, *)
          bearer_request?(req) ? false : super
        end
      end
    end
  end
end
