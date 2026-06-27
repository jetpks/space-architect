# frozen_string_literal: true

module Space
  module Server
    module Actions
      module Sessions
        # OmniAuth GitHub callback. OmniAuth's request-phase (POST /auth/github)
        # already guards CSRF via AuthenticityTokenProtection (key :csrf). This
        # action must be OUT of Hanami Action CSRF because the callback POST
        # carries OmniAuth's own token, not Hanami's _csrf_token.
        class Create < Space::Server::Action
          include Space::Server::Deps["operations.authenticate_user"]

          def handle(req, res)
            auth = req.env["omniauth.auth"]

            unless auth
              res.redirect_to "/auth/failure?message=omniauth_error"
              return
            end

            user = authenticate_user.call(auth)

            # Session fixation guard: :renew tells Rack::Session to delete the old
            # session and generate a new ID before committing.
            req.env["rack.session.options"][:renew] = true
            req.session.clear
            req.session[:user_id] = user.id

            res.flash["notice"] = "Signed in as #{user.username}."
            res.redirect_to "/"
          end

          private

          def verify_csrf_token?(*, **)
            false
          end
        end
      end
    end
  end
end
