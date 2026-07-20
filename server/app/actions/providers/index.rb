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
            providers_repo.list_for_user(user.id).map do |provider|
              { id: provider.id, name: provider.name, base_url: provider.base_url,
                api_key_ref: provider.api_key_ref, flavors: provider.flavors }
            end
          end
        end
      end
    end
  end
end
