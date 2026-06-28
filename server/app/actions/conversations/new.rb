# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Conversations
        class New < Space::Server::Action
          def handle(req, res)
            require_login(req, res)
            render_inertia(req, res, "Conversations/New")
          end
        end
      end
    end
  end
end
