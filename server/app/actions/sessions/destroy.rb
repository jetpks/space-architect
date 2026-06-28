# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Sessions
        class Destroy < Space::Server::Action
          def handle(req, res)
            req.env["rack.session.options"][:renew] = true
            req.session.clear
            res.flash["notice"] = "Signed out."
            res.redirect_to "/"
          end
        end
      end
    end
  end
end
