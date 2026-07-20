# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Providers
        class Destroy < Space::Server::Action
          include Space::Server::Deps["repos.providers_repo"]

          def handle(req, res)
            user = require_login(req, res)

            provider = providers_repo.by_id_for_user(req.params[:id].to_i, user.id)
            halt_not_found(res) unless provider

            providers_repo.delete(provider.id)
            res.flash["notice"] = "Provider deleted."
            redirect_inertia(req, res, "/providers")
          end
        end
      end
    end
  end
end
