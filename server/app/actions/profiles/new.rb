# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Profiles
        class New < Space::Server::Action
          include Space::Server::Deps["repos.providers_repo"]

          def handle(req, res)
            user = require_login(req, res)
            render_inertia(req, res, "Profiles/New", props: { providers: provider_list(user) })
          end

          private

          def provider_list(user)
            Providers::Serializer.call(providers_repo.list_for_user(user.id))
          end
        end
      end
    end
  end
end
