# auto_register: false
# frozen_string_literal: true

require "hanami/action"
require "dry/monads"
require "json"
require "inertia_hanami"

module Space
  module Server
    class Action < Hanami::Action
      include Dry::Monads[:result]
      include InertiaHanami::Action
      include Space::Server::Deps["repos.users_repo", "settings"]

      private

      JSON_CONTENT_TYPE = "application/json; charset=utf-8"

      # Session-only lookup. Takes req explicitly; safe when actions are singleton
      # objects (no per-request instance state).
      def current_user(req)
        return nil unless (uid = req.session[:user_id])
        users_repo.by_pk(uid)
      end

      # Bearer-token lookup. Returns a User only when ALL hold:
      #   - settings.ingest_token is configured and non-empty
      #   - request carries Authorization: Bearer <t>
      #   - <t> constant-time-equals the configured token
      #   - settings.ingest_user_id resolves to a real user
      # Nil/empty token can NEVER match — guarded explicitly before secure_compare.
      def token_user(req)
        token = settings.ingest_token
        return nil if token.nil? || token.empty?

        auth = req.env["HTTP_AUTHORIZATION"].to_s
        return nil unless auth.start_with?("Bearer ")

        bearer = auth[7..]
        return nil unless ::Rack::Utils.secure_compare(token, bearer)

        uid = settings.ingest_user_id
        return nil if uid.nil?

        users_repo.by_pk(uid)
      end

      def authenticated_user(req)
        current_user(req) || token_user(req)
      end

      def render_json(res, data, status: 200)
        res.status = status
        res.content_type = JSON_CONTENT_TYPE
        res.body = JSON.generate(data)
      end

      # Set JSON content-type before halting so it survives the throw/catch.
      # Hanami::Action#finish sets res.status+body from the halted tuple but
      # does NOT reset content_type, so this assignment persists.
      def halt_not_found(res)
        res.content_type = JSON_CONTENT_TYPE
        halt 404, JSON.generate(error: "Not found")
      end

      def halt_unprocessable(res, errors)
        res.content_type = JSON_CONTENT_TYPE
        halt 422, JSON.generate(errors: errors)
      end

      # Redirect with a flash message. res.redirect_to calls Halt.call (throw :halt),
      # aborting handle — no separate halt needed after this call.
      def redirect_with_flash(res, to, notice: nil, alert: nil)
        res.flash["notice"] = notice if notice
        res.flash["alert"] = alert if alert
        res.redirect_to(to)
      end

      # redirect_back with flash: uses Referer or fallback URL.
      def bearer_request?(req)
        req.env["HTTP_AUTHORIZATION"].to_s.start_with?("Bearer ")
      end

      def redirect_back_with_flash(req, res, fallback:, notice: nil, alert: nil)
        to = req.env["HTTP_REFERER"].to_s
        to = fallback if to.empty?
        redirect_with_flash(res, to, notice: notice, alert: alert)
      end

      # Returns the current user or redirects to / with flash if anonymous.
      def require_login(req, res)
        user = current_user(req)
        redirect_with_flash(res, "/", alert: "Please sign in to continue.") unless user
        user
      end

      # Two-tier owner guard matching oracle behavior (require_login fires first for
      # owner-only actions in the oracle, then require_owner for non-owners).
      # Returns the current user, or redirects with flash and halts.
      def require_owner(req, res, conversation)
        user = current_user(req)
        unless user
          redirect_with_flash(res, "/", alert: "Please sign in to continue.")
        end
        unless conversation.owned_by?(user)
          redirect_with_flash(res, "/", alert: "Not authorized.")
        end
        user
      end
    end
  end
end
