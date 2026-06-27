# frozen_string_literal: true

require "inertia_hanami"
require "vite_hanami"

# Hanami 2.3 provider files in config/providers/ are loaded lazily (only when the
# provider key is accessed or when container.finalize! runs at boot). Calling
# InertiaHanami.configure in the `start` block guarantees it runs both in production
# (finalize!) and in test (Space::Server::App.start(:inertia)). The layout + version callables
# reference Space::Server::App["vite"] lazily — invoked at render/request time after boot.
Hanami.app.register_provider(:inertia) do
  start do
    InertiaHanami.configure do |c|
      c.version         = -> { Space::Server::App["vite"].digest }
      c.encrypt_history = true
      c.root_id         = "app"

      c.shared_props = ->(req) {
        uid  = req.session_enabled? ? req.session[:user_id] : nil
        user = uid ? Space::Server::App["repos.users_repo"].by_pk(uid) : nil
        cu   = user ? { id: user.id, username: user.username, avatar_url: user.avatar_url } : nil
        flash_data = {}
        if req.session_enabled?
          f = req.flash
          flash_data[:notice] = f["notice"] if f.key?("notice")
          flash_data[:alert]  = f["alert"]  if f.key?("alert")
        end
        { current_user: cu, flash: flash_data }
      }

      # Request-blind layout callable: receives the inertia_body string (script element + div).
      # CSP meta:  OMITTED (A2 — disabled in oracle).
      # yield :head / inertia_ssr_head: OMITTED (F3 — CSR, client-side head management).
      # CSRF: delivered via XSRF-TOKEN cookie by the middleware; no meta tag needed.
      c.layout = ->(inertia_body) {
        vite    = Space::Server::App["vite"]
        refresh = ViteHanami::TagHelpers.vite_react_refresh_tag(vite: vite)
        client  = ViteHanami::TagHelpers.vite_client_tag(vite: vite)
        entry   = ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx", vite: vite)
        [
          "<!DOCTYPE html>",
          '<html class="dark">',
          "  <head>",
          "    <title data-inertia>Chat Share</title>",
          '    <meta name="viewport" content="width=device-width,initial-scale=1">',
          '    <meta name="apple-mobile-web-app-capable" content="yes">',
          '    <meta name="application-name" content="Chat Share">',
          '    <meta name="mobile-web-app-capable" content="yes">',
          '    <link rel="icon" href="/icon.png" type="image/png">',
          '    <link rel="icon" href="/icon.svg" type="image/svg+xml">',
          '    <link rel="apple-touch-icon" href="/icon.png">',
          refresh,
          client,
          entry,
          "  </head>",
          "  <body>#{inertia_body}</body>",
          "</html>",
        ].join("\n")
      }
    end
  end
end
