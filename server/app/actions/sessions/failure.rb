# frozen_string_literal: true

module Architect
  module Actions
    module Sessions
      class Failure < Architect::Action
        def handle(req, res)
          message = req.params[:message].to_s
          res.flash["alert"] = "Authentication failed: #{message}."
          res.redirect_to "/"
        end
      end
    end
  end
end
