# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Jobs
        class New < Space::Server::Action
          include Space::Server::Deps["repos.profiles_repo", "repos.providers_repo"]

          def handle(req, res)
            user = require_login(req, res)
            render_inertia(req, res, "Jobs/New",
                            props: { profiles: profile_list(user), providers: provider_list(user) })
          end

          private

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
