# frozen_string_literal: true

require "rack"

module InertiaHanami
  # Plain Rack middleware handling cross-cutting Inertia protocol concerns:
  # version-409 + X-Inertia-Location + flash reflash (GET only);
  # 303 coercion for PUT/PATCH/DELETE redirects;
  # session :inertia_errors cleanup on non-redirect responses;
  # XSRF→CSRF header bridge.
  #
  # Port of inertia_rails 3.21.1 middleware.rb behavior, stripped of
  # ActionDispatch/action_controller dependencies.
  class Middleware
    FLASH_SESSION_KEY    = "_flash"
    COERCIBLE_METHODS    = %w[PUT PATCH DELETE].freeze
    REDIRECT_STATUSES    = [301, 302].freeze
    private_constant :FLASH_SESSION_KEY, :COERCIBLE_METHODS, :REDIRECT_STATUSES

    def initialize(app, config: nil)
      @app    = app
      @config = config || InertiaHanami.configuration
    end

    def call(env)
      # inertia_rails middleware.rb:108 — copy before app runs so the host CSRF check sees it
      copy_xsrf_to_csrf!(env)

      # Save current flash before app call so we can reflash on 409
      # (the Hanami action's Session#finish sweeps the flash; we restore it)
      saved_flash = env["rack.session"]&.[](FLASH_SESSION_KEY)

      status, headers, body = @app.call(env)

      # inertia_rails middleware.rb:66-68,102-105 — version-409, GET only
      if stale_inertia_get?(env)
        restore_flash!(env, saved_flash)
        return force_refresh(env)
      end

      # inertia_rails middleware.rb:33-37 — session cleanup on non-redirect
      cleanup_inertia_session!(env, status)

      # inertia_rails middleware.rb:39,62-64 — 303 coercion for non-GET redirectable methods
      status = 303 if inertia_non_post_redirect?(env, status)

      set_xsrf_cookie!(env, headers)

      [status, headers, body]
    end

    private

    # inertia_rails middleware.rb:87 — Inertia request detection
    def inertia_request?(env)
      env["HTTP_X_INERTIA"].to_s != ""
    end

    def get?(env)
      env["REQUEST_METHOD"] == "GET"
    end

    def version_stale?(env)
      server_version = @config.resolved_version
      return false if server_version.nil?
      env["HTTP_X_INERTIA_VERSION"].to_s != server_version.to_s
    end

    # inertia_rails middleware.rb:66-68 — GET only; POST/PUT/PATCH/DELETE never 409
    def stale_inertia_get?(env)
      get?(env) && inertia_request?(env) && version_stale?(env)
    end

    # inertia_rails middleware.rb:39,62-64 — 302 + PUT/PATCH/DELETE → 303
    def inertia_non_post_redirect?(env, status)
      status == 302 && inertia_request?(env) && COERCIBLE_METHODS.include?(env["REQUEST_METHOD"])
    end

    def redirect_status?(status)
      REDIRECT_STATUSES.include?(status)
    end

    # inertia_rails middleware.rb:33-37 — guard on session loaded; skip on redirect
    def cleanup_inertia_session!(env, status)
      return if redirect_status?(status)
      return unless (session = env["rack.session"])
      session.delete("inertia_errors")
      session.delete("inertia_clear_history")
    end

    # Restore saved flash into the session after the app call (reflash for 409 hard-reload)
    def restore_flash!(env, saved_flash)
      return unless (session = env["rack.session"])
      if saved_flash
        session[FLASH_SESSION_KEY] = saved_flash
      else
        session.delete(FLASH_SESSION_KEY)
      end
    end

    # inertia_rails middleware.rb:108 — before app call
    def copy_xsrf_to_csrf!(env)
      if env["HTTP_X_XSRF_TOKEN"] && !env["HTTP_X_CSRF_TOKEN"]
        env["HTTP_X_CSRF_TOKEN"] = env["HTTP_X_XSRF_TOKEN"]
      end
    end

    # Set XSRF-TOKEN cookie = live session CSRF token so Inertia v3 XHR can read it.
    # JS-readable (not HttpOnly); rides all responses including redirects.
    # Mirrors config/app.rb:61 — checks both symbol and string session keys.
    def set_xsrf_cookie!(env, headers)
      session = env["rack.session"]
      return unless session
      token = session[:_csrf_token] || session["_csrf_token"]
      return unless token
      Rack::Utils.set_cookie_header!(headers, "XSRF-TOKEN", {
        value:     token,
        path:      "/",
        same_site: :lax,
        http_only: false,
        secure:    Rack::Request.new(env).ssl?
      })
    end

    # inertia_rails middleware.rb:102-105 — force full-page reload to original URL
    def force_refresh(env)
      req = Rack::Request.new(env)
      [409, {"x-inertia-location" => req.url}, []]
    end
  end
end
