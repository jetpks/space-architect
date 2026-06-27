# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Sessions
        class Failure < Space::Server::Action
          def handle(req, res)
            message = req.params[:message].to_s
            res.flash["alert"] = "Authentication failed: #{message}."
            res.redirect_to "/"
          end
        end
      end
    end
  end
end
