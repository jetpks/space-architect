# frozen_string_literal: true

module Architect
  module Actions
    module Conversations
      class New < Architect::Action
        def handle(req, res)
          require_login(req, res)
          render_inertia(req, res, "Conversations/New")
        end
      end
    end
  end
end
