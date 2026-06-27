# frozen_string_literal: true

module Architect
  module Actions
    module Runs
      class Ingest < Architect::Action
        include Architect::Deps["repos.runs_repo", "repos.conversations_repo", "repos.messages_repo", "redis"]

        def handle(req, res)
          run = runs_repo.by_pk(req.params[:id].to_i)
          halt_not_found(res) unless run

          user = authenticated_user(req)
          unless user
            res.content_type = JSON_CONTENT_TYPE
            halt 401, JSON.generate(error: "Sign in required.")
          end

          unless run.owned_by?(user)
            res.content_type = JSON_CONTENT_TYPE
            halt 403, JSON.generate(error: "Not authorized.")
          end

          runs_repo.update(run.id, status: 1, updated_at: Time.now) if run.pending?

          persistor = Architect::Runs::Persistor.new(conversations_repo, messages_repo)
          result = Architect::Runs::Ingest.new(redis, persistor: persistor).call(run, req.env["rack.input"])

          final_status = case result[:status]
            when :complete then 2
            when :failed   then 3
            else 1
          end
          runs_repo.update(run.id, status: final_status, conversation_id: persistor.conversation_id, updated_at: Time.now)

          status_label = { 1 => :live, 2 => :complete, 3 => :failed }.fetch(final_status)
          render_json(res, { id: run.id, status: status_label, events: result[:events] }, status: 202)
        end

        private

        def verify_csrf_token?(req, *)
          bearer_request?(req) ? false : super
        end
      end
    end
  end
end
