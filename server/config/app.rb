# frozen_string_literal: true

require "hanami"
require "hanami_credentials"
require "hanami_healthcheck"
require "hanami_force_ssl"
require "rack/protection/host_authorization"
require "omniauth"
require "omniauth-github"
require "inertia_hanami"
require "vite_hanami"

module Space
  module Server
    class App < Hanami::App
      config.settings_store = HanamiCredentials::Store.new(
        content_path: Pathname(__dir__).join("credentials.yml.enc"),
        env_key: "SPACE_SERVER_MASTER_KEY",
        key_path: Pathname(__dir__).join("master.key")
      )

      # Redirect 127.0.0.1 → localhost (Vite dev server uses localhost; this keeps
      # the browser and Vite on the same origin so HMR works). Port via Rack
      # middleware since hanami-router 2.3.1 has no host-constraint DSL.
      HostRedirect = Class.new do
        def initialize(app) = @app = app

        def call(env)
          return @app.call(env) unless (env["HTTP_HOST"] || "").start_with?("127.0.0.1")

          loc = "#{env['rack.url_scheme'] || 'http'}://localhost:#{env['SERVER_PORT']}#{env['PATH_INFO']}"
          loc = "#{loc}?#{env['QUERY_STRING']}" unless env["QUERY_STRING"].to_s.empty?
          [301, {"location" => loc, "content-length" => "0", "content-type" => "text/plain"}, []]
        end
      end

      # Prevents Hanami::Router#_params (hanami-router 2.3.1 lib/hanami/router.rb:991-993)
      # from draining rack.input before the ingest action reads it. _params does
      # rewind→read→rewind on rack.input when ROUTER_PARSED_BODY is absent;
      # Protocol::Rack::Input#rewind is a no-op on the one-shot Fixed body, so the
      # body is consumed and the action's input.gets returns nil → 0 events.
      # Setting ROUTER_PARSED_BODY here short-circuits _params for this route only,
      # leaving rack.input untouched for incremental streaming XADD.
      IngestBodyPassthrough = Class.new do
        INGEST_ROUTE = %r{\A/runs/\d+/ingest\z}

        def initialize(app) = @app = app

        def call(env)
          if env["REQUEST_METHOD"] == "POST" && INGEST_ROUTE.match?(env["PATH_INFO"])
            env[Hanami::Router::ROUTER_PARSED_BODY] ||= {}
          end
          @app.call(env)
        end
      end

      config.actions.sessions = :cookie, {
        key: "_space_server_session",
        secret: settings.session_secret
      }
      # csrf_protection defaults to true when sessions are enabled;
      # hanami-controller auto-disables it in HANAMI_ENV=test

      # OmniAuth GitHub OAuth — on_failure routes to our failure action via redirect.
      # Captured here so the block below closes over resolved values (not the lazy setting).
      _github_id     = settings.github_client_id
      _github_secret = settings.github_client_secret

      OmniAuth.config.on_failure = proc do |env|
        msg = Rack::Utils.escape(env["omniauth.error.type"]&.to_s || "unknown")
        [302, {"location" => "/auth/failure?message=#{msg}", "content-type" => "text/html", "content-length" => "0"}, []]
      end

      # Request-phase CSRF for OmniAuth. The SPA sign-in form (Nav.tsx) submits Hanami's own
      # `_csrf_token` (read from the XSRF-TOKEN cookie) as `authenticity_token`. Validate the
      # request phase against THAT session token — one CSRF token shared by Hanami actions and
      # OmniAuth — mirroring the Rails oracle's single token (omniauth-rails_csrf_protection).
      # (Replaces OmniAuth's default rack-protection AuthenticityToken, which checks a separate
      # `:csrf` session key the frontend never sends.) Raises AuthenticityError → on_failure.
      OmniAuth.config.request_validation_phase = lambda do |env|
        session = env["rack.session"] || {}
        expected = (session[:_csrf_token] || session["_csrf_token"]).to_s
        submitted = (Rack::Request.new(env).params["authenticity_token"] || env["HTTP_X_CSRF_TOKEN"]).to_s

        unless !expected.empty? && !submitted.empty? && Rack::Utils.secure_compare(expected, submitted)
          raise OmniAuth::AuthenticityError, "invalid authenticity token"
        end
      end

      config.middleware.use OmniAuth::Builder do
        provider :github, _github_id, _github_secret,
          scope: "read:user,user:email,read:org"
      end

      # OmniAuth's request phase 302-redirects the sign-in POST to github.com, and the
      # CSP `form-action` directive is enforced across the whole redirect chain — so the
      # provider origin must be allow-listed (every env; the redirect happens in prod too).
      # Chrome reports the violation against the pre-redirect /auth/github URL, which is
      # why it misreads as a 'self' block.
      config.actions.content_security_policy[:form_action] += " https://github.com"

      config.middleware.use HostRedirect
      config.middleware.use IngestBodyPassthrough

      # JSON request bodies (Jobs::Create's browser/Bearer POST /jobs — I10). Hanami
      # already auto-appends a form+json Hanami::Middleware::BodyParser at the very end
      # of the stack (Hanami::Config#use_body_parser_middleware, unconditional whenever
      # hanami-router + hanami-controller are bundled — verified in hanami-2.3.2's
      # config.rb), so JSON parsing technically works without this line. It's registered
      # explicitly anyway so the JSON contract is legible here rather than resting on
      # that implicit default, and so its position relative to IngestBodyPassthrough is
      # pinned rather than incidental. Placed AFTER IngestBodyPassthrough: that
      # middleware pre-sets ROUTER_PARSED_BODY for /runs/:id/ingest, and BodyParser's
      # own `call` short-circuits whenever that key is already present — so the ingest
      # stream is skipped by construction, not by content-type (application/x-ndjson)
      # alone. :json only — multipart form-data (Conversations upload) keeps relying on
      # Hanami's own default registration.
      config.middleware.use :body_parser, :json

      # Dev-only: the Vite dev server (port 3036) serves ES modules cross-origin and injects an
      # inline React-refresh preamble — both blocked by the default `script-src 'self'` CSP, which
      # renders a blank page. Relax script/connect/style to the dev server (+ inline/eval for HMR)
      # in development only; production keeps Hanami's strict default CSP.
      if Hanami.env?(:development)
        vite = "http://localhost:3036"
        csp = config.actions.content_security_policy
        csp[:script_src]  += " 'unsafe-inline' 'unsafe-eval' #{vite}"
        csp[:connect_src] += " #{vite} ws://localhost:3036"
        csp[:style_src]   += " #{vite}"
        csp[:font_src]    += " #{vite}"
      end

      # Dev-only: proxy /vite-dev/ asset paths to the Vite dev server before the app handles them.
      config.middleware.use ViteHanami::DevServerProxy if Hanami.env?(:development)

      # Inertia protocol: 409 stale-reload, 303 coercion, errors cleanup, XSRF→CSRF bridge.
      # Must be inside Rack::Session::Cookie (slice.rb:1088 > 1075); added last so it wraps
      # the router/actions innermost.
      config.middleware.use InertiaHanami::Middleware
    end
  end
end
