# frozen_string_literal: true

# Integration tests for force-ssl + host-auth as assembled at the rackup layer.
# After the C1 fix these middlewares live in config.ru, not config/app.rb, so
# tests drive a Rack::Builder stack that mirrors config.ru exactly:
#   HanamiForceSSL::Middleware → Rack::Protection::HostAuthorization → inner app
# This exercises the same order that runs in production (both before Rack::Session::Cookie).

require "minitest/autorun"
require "rack/mock"
require "rack/builder"
require "rack/protection/host_authorization"
require "hanami_force_ssl"

INNER_APP = ->(env) {
  [200, { "content-type" => "text/plain", "content-length" => "2" }, ["ok"]]
}

module RackupStackHelper
  # Mirrors config.ru: force-ssl outermost, then host-auth, then inner.
  # force_ssl: false disables redirect (models dev/test default) for host-auth isolation.
  def rackup_stack(permitted_hosts:, force_ssl: true, inner: INNER_APP)
    b = Rack::Builder.new
    b.use HanamiForceSSL::Middleware,
      redirect: force_ssl ? { exclude: ->(req) { req.path == "/up" } } : false
    b.use Rack::Protection::HostAuthorization,
      permitted_hosts: permitted_hosts,
      allow_if:        ->(env) { env["PATH_INFO"] == "/up" }
    b.run inner
    b.to_app
  end
end

# ─── G3: Rack::Protection::HostAuthorization wired ───────────────────────────

class HostAuthorizationWiringTest < Minitest::Test
  include RackupStackHelper

  # G3: default permitted_hosts = [] → all hosts allowed (no lockout in dev/test)
  def test_empty_permitted_hosts_allows_all
    app = rackup_stack(permitted_hosts: [], force_ssl: false)
    env = Rack::MockRequest.env_for("http://anything.example.com/")
    status, _, _ = app.call(env)
    assert_equal 200, status
  end

  # G3: non-empty permitted_hosts + disallowed host → 403
  def test_disallowed_host_returns_403
    app = rackup_stack(permitted_hosts: ["www.example.com"], force_ssl: false)
    env = Rack::MockRequest.env_for("http://attacker.example.com/",
      "HTTP_HOST" => "attacker.example.com")
    status, _, _ = app.call(env)
    assert_equal 403, status
  end

  # G3: allowed host → passes through
  def test_allowed_host_passes
    app = rackup_stack(permitted_hosts: ["www.example.com"], force_ssl: false)
    env = Rack::MockRequest.env_for("http://www.example.com/",
      "HTTP_HOST" => "www.example.com")
    status, _, _ = app.call(env)
    assert_equal 200, status
  end

  # G3: /up reachable regardless of Host (allow_if exemption)
  def test_up_path_exempt_from_host_restriction
    app = rackup_stack(permitted_hosts: ["www.example.com"], force_ssl: false)
    env = Rack::MockRequest.env_for("http://attacker.example.com/up",
      "HTTP_HOST" => "attacker.example.com")
    status, _, _ = app.call(env)
    assert_equal 200, status
  end
end

# ─── G4: rackup stack order — force-ssl outermost, host-auth second ───────────

class TransportSecurityStackTest < Minitest::Test
  include RackupStackHelper

  # /up exempt from both force-ssl redirect and host-auth restriction
  def test_up_exempt_from_force_ssl_and_host_auth
    app = rackup_stack(permitted_hosts: ["www.example.com"])
    env = Rack::MockRequest.env_for("http://attacker.example.com/up",
      "HTTP_HOST" => "attacker.example.com")
    status, _, _ = app.call(env)
    assert_equal 200, status
  end

  # force-ssl is outermost in rackup: HTTP + disallowed host → 301, not 403
  # (force-ssl intercepts before host-auth can fire)
  def test_force_ssl_outermost_fires_before_host_auth
    app = rackup_stack(permitted_hosts: ["www.example.com"])
    env = Rack::MockRequest.env_for("http://attacker.example.com/foo",
      "HTTP_HOST" => "attacker.example.com")
    status, _, _ = app.call(env)
    assert_equal 301, status
  end

  # HTTPS + allowed host → passes through to inner app
  def test_https_allowed_host_passes
    app = rackup_stack(permitted_hosts: ["www.example.com"])
    env = Rack::MockRequest.env_for("https://www.example.com/",
      "HTTP_HOST" => "www.example.com")
    status, _, _ = app.call(env)
    assert_equal 200, status
  end

  # HTTPS + disallowed host → 403 (force-ssl passes HTTPS through, host-auth blocks)
  def test_https_disallowed_host_blocked_by_host_auth
    app = rackup_stack(permitted_hosts: ["www.example.com"])
    env = Rack::MockRequest.env_for("https://attacker.example.com/",
      "HTTP_HOST" => "attacker.example.com")
    status, _, _ = app.call(env)
    assert_equal 403, status
  end

  # ORDER PROOF: force-ssl and host-auth intercept before the session/app layer.
  # A probe placed at the inner-app position tracks whether it was reached.
  # HTTP request → force-ssl 301s → probe never invoked, proving outermost ordering.
  def test_rackup_middlewares_intercept_before_session_layer
    session_layer_reached = false
    session_probe = ->(env) { session_layer_reached = true; INNER_APP.call(env) }

    app = rackup_stack(permitted_hosts: [], inner: session_probe)
    env = Rack::MockRequest.env_for("http://www.example.com/")
    status, _, _ = app.call(env)

    assert_equal 301, status
    refute session_layer_reached, "session/app layer must not be reached when force-ssl redirects"
  end
end
