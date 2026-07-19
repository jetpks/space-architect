# frozen_string_literal: true

require_relative "../../contracts/create_job"

module Space
  module Server
    module Actions
      module Jobs
        class Create < Space::Server::Action
          include Space::Server::Deps["repos.jobs_repo"]

          CONTRACT = Contracts::CreateJob.new

          # permissions is the one defaultable environment field whose sub-defaults
          # live inside a nested `hash do` block (see create_job.rb) — dry-schema
          # only fills nested-block defaults when the key itself is present, so a
          # fully-omitted `permissions` key is defaulted here instead.
          DEFAULT_PERMISSIONS = { network: false, mounts: [] }.freeze

          def handle(req, res)
            user = authenticated_user(req)
            unless user
              res.content_type = JSON_CONTENT_TYPE
              halt 401, JSON.generate(error: "Sign in required.")
            end

            result = CONTRACT.call(req.params.to_h)
            halt_unprocessable(res, result.errors.to_h) if result.failure?

            now = Time.now
            job = jobs_repo.create(user_id: user.id, spec: spec_for(result), created_at: now, updated_at: now)

            render_json(res, { id: job.id, status: job.status }, status: 201)
          end

          private

          def spec_for(result)
            spec = result.to_h
            spec[:environment] = spec[:environment].merge(permissions: DEFAULT_PERMISSIONS) unless spec[:environment].key?(:permissions)
            spec
          end

          def verify_csrf_token?(req, *)
            bearer_request?(req) ? false : super
          end
        end
      end
    end
  end
end
