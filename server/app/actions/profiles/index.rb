# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Profiles
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.profiles_repo"]

          def handle(req, res)
            user = require_login(req, res)
            render_inertia(req, res, "Profiles/Index", props: { profiles: profile_list(user) })
          end

          private

          def profile_list(user)
            profiles_repo.list_for_user(user.id).map do |profile|
              { id: profile.id, name: profile.name, harness_type: profile.harness_type, spec: profile.spec }
            end
          end
        end
      end
    end
  end
end
