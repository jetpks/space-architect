# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Profiles
        class New < Space::Server::Action
          def handle(req, res)
            require_login(req, res)
            render_inertia(req, res, "Profiles/New")
          end
        end
      end
    end
  end
end
