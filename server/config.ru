# frozen_string_literal: true

require "hanami/boot"

# Transport security wired at the rackup layer rather than config/app.rb because
# Hanami 2.3 config.middleware.use appends after framework middleware (slice.rb:1088),
# so Rack::Session::Cookie would precede these. config.ru wrapping is truly outermost.
_settings = Architect::App["settings"]

use HanamiForceSSL::Middleware,
  redirect:   _settings.force_ssl ? { exclude: ->(req) { req.path == "/up" } } : false,
  assume_ssl: _settings.assume_ssl

use Rack::Protection::HostAuthorization,
  permitted_hosts: _settings.permitted_hosts,
  allow_if:        ->(env) { env["PATH_INFO"] == "/up" }

run Hanami.app
