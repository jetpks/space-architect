# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Profiles
        class Destroy < Space::Server::Action
          include Space::Server::Deps["repos.profiles_repo"]

          def handle(req, res)
            user = require_login(req, res)

            profile = profiles_repo.by_pk(req.params[:id].to_i)
            halt_not_found(res) unless profile && profile.owned_by?(user)

            profiles_repo.delete(profile.id)
            res.flash["notice"] = "Profile deleted."
            redirect_inertia(req, res, "/profiles")
          end
        end
      end
    end
  end
end
