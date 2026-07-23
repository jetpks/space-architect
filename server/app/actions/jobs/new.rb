# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Jobs
        class New < Space::Server::Action
          include Space::Server::Deps["repos.profiles_repo", "repos.providers_repo", "repos.jobs_repo"]

          def handle(req, res)
            user = require_login(req, res)
            props = { profiles: profile_list(user), providers: provider_list(user) }.merge(prefill_props(req, user))
            render_inertia(req, res, "Jobs/New", props: props)
          end

          private

          # Re-run prefill: only when `from` names a job owned by the current user.
          def prefill_props(req, user)
            from_id = req.params[:from].to_i
            return {} unless from_id.positive?

            job = jobs_repo.by_pk(from_id)
            job&.owned_by?(user) ? { prefill_spec: job.spec } : {}
          end

          def profile_list(user)
            profiles_repo.list_for_user(user.id).map do |profile|
              { id: profile.id, name: profile.name, harness_type: profile.harness_type, spec: profile.spec }
            end
          end

          def provider_list(user)
            Providers::Serializer.call(providers_repo.list_for_user(user.id))
          end
        end
      end
    end
  end
end
