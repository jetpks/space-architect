# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Providers
        class Index < Space::Server::Action
          include Space::Server::Deps["repos.providers_repo"]

          def handle(req, res)
            user = require_login(req, res)
            render_inertia(req, res, "Providers/Index", props: { providers: provider_list(user) })
          end

          private

          def provider_list(user)
            Serializer.call(providers_repo.list_for_user(user.id))
          end
        end
      end
    end
  end
end
