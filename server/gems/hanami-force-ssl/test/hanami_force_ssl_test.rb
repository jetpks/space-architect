# frozen_string_literal: true

require_relative "test_helper"

# Minimal Rack-3-compliant inner apps for testing.
OK_APP = ->(env) {
  [200, { "content-type" => "text/html", "content-length" => "2" }, ["OK"]]
}

COOKIE_APP = ->(env) {
  [200, {
    "content-type"  => "text/html",
    "content-length" => "2",
    "set-cookie"    => ["a=1; path=/", "b=2; path=/"]
  }, ["OK"]]
}

COOKIE_SECURE_APP = ->(env) {
  [200, {
    "content-type"  => "text/html",
    "content-length" => "2",
    "set-cookie"    => ["a=1; path=/; secure", "b=2; path=/"]
  }, ["OK"]]
}

# ─── G1: redirect behavior ────────────────────────────────────────────────────

class RedirectTest < Minitest::Test
  def middleware(**opts)
    HanamiForceSSL::Middleware.new(OK_APP, **opts)
  end

  # G1: HTTP GET → 301
  def test_http_get_redirects_301
    m = middleware
    env = Rack::MockRequest.env_for("http://example.com/foo")
    status, headers, _ = m.call(env)
    assert_equal 301, status
    assert_equal "https://example.com/foo", headers["location"]
  end

  # G1: HTTP HEAD → 301
  def test_http_head_redirects_301
    m = middleware
    env = Rack::MockRequest.env_for("http://example.com/", "REQUEST_METHOD" => "HEAD")
    status, _, _ = m.call(env)
    assert_equal 301, status
  end

  # G1: HTTP POST → 307 (method-preserving)
  def test_http_post_redirects_307
    m = middleware
    env = Rack::MockRequest.env_for("http://example.com/", "REQUEST_METHOD" => "POST")
    status, _, _ = m.call(env)
    assert_equal 307, status
  end

  # G1: HTTP PATCH → 307
  def test_http_patch_redirects_307
    m = middleware
    env = Rack::MockRequest.env_for("http://example.com/", "REQUEST_METHOD" => "PATCH")
    status, _, _ = m.call(env)
    assert_equal 307, status
  end

  # G1: query string preserved in Location
  def test_redirect_preserves_query_string
    m = middleware
    env = Rack::MockRequest.env_for("http://example.com/search?q=hello&page=2")
    _, headers, _ = m.call(env)
    assert_equal "https://example.com/search?q=hello&page=2", headers["location"]
  end

  # G1: non-standard port included in Location
  def test_redirect_includes_non_standard_port
    m = middleware
    env = Rack::MockRequest.env_for("http://example.com:3000/foo")
    _, headers, _ = m.call(env)
    assert_equal "https://example.com:3000/foo", headers["location"]
  end

  # G1: port 443 omitted from Location
  def test_redirect_omits_port_443
    m = middleware(redirect: { port: 443 })
    env = Rack::MockRequest.env_for("http://example.com/foo")
    _, headers, _ = m.call(env)
    assert_equal "https://example.com/foo", headers["location"]
  end

  # G1: port 80 omitted from Location
  def test_redirect_omits_port_80
    m = middleware(redirect: { port: 80 })
    env = Rack::MockRequest.env_for("http://example.com/foo")
    _, headers, _ = m.call(env)
    assert_equal "https://example.com/foo", headers["location"]
  end

  # G1: redirect host override
  def test_redirect_host_override
    m = middleware(redirect: { host: "secure.example.com" })
    env = Rack::MockRequest.env_for("http://example.com/foo")
    _, headers, _ = m.call(env)
    assert_match %r{\Ahttps://secure\.example\.com}, headers["location"]
  end

  # G1: redirect port override (non-standard)
  def test_redirect_port_override_included
    m = middleware(redirect: { port: 8443 })
    env = Rack::MockRequest.env_for("http://example.com/foo")
    _, headers, _ = m.call(env)
    assert_equal "https://example.com:8443/foo", headers["location"]
  end

  # G1: HTTPS request passes through — no redirect
  def test_https_request_passes_through
    m = middleware
    env = Rack::MockRequest.env_for("https://example.com/")
    status, _, _ = m.call(env)
    assert_equal 200, status
  end

  # G1: redirect Content-Type header
  def test_redirect_content_type_header
    m = middleware
    env = Rack::MockRequest.env_for("http://example.com/")
    _, headers, _ = m.call(env)
    assert_equal "text/html; charset=utf-8", headers["content-type"]
  end

  # G1: redirect: false → no redirect
  def test_redirect_false_disables_redirect
    m = middleware(redirect: false)
    env = Rack::MockRequest.env_for("http://example.com/")
    status, _, _ = m.call(env)
    assert_equal 200, status
  end
end

# ─── G2: HSTS ─────────────────────────────────────────────────────────────────

class HSTSTest < Minitest::Test
  def middleware(**opts)
    HanamiForceSSL::Middleware.new(OK_APP, **opts)
  end

  def ssl_env(path = "/")
    Rack::MockRequest.env_for("https://example.com#{path}")
  end

  # G2: HSTS default on SSL response
  def test_hsts_default_header
    m = middleware
    _, headers, _ = m.call(ssl_env)
    assert_equal "max-age=63072000; includeSubDomains", headers["strict-transport-security"]
  end

  # G2: custom expires
  def test_hsts_custom_expires
    m = middleware(hsts: { expires: 3600 })
    _, headers, _ = m.call(ssl_env)
    assert_equal "max-age=3600; includeSubDomains", headers["strict-transport-security"]
  end

  # G2: subdomains: false → no includeSubDomains
  def test_hsts_subdomains_false
    m = middleware(hsts: { subdomains: false })
    _, headers, _ = m.call(ssl_env)
    assert_equal "max-age=63072000", headers["strict-transport-security"]
  end

  # G2: preload: true
  def test_hsts_preload
    m = middleware(hsts: { subdomains: true, preload: true })
    _, headers, _ = m.call(ssl_env)
    assert_equal "max-age=63072000; includeSubDomains; preload", headers["strict-transport-security"]
  end

  # G2: hsts: false → max-age=0 (forget)
  def test_hsts_false_sets_max_age_zero
    m = middleware(hsts: false)
    _, headers, _ = m.call(ssl_env)
    assert_match(/\Amax-age=0/, headers["strict-transport-security"])
  end

  # G2: HSTS does NOT overwrite an existing header
  def test_hsts_does_not_overwrite_existing
    inner = ->(env) {
      [200, {
        "content-type"              => "text/html",
        "content-length"            => "2",
        "strict-transport-security" => "max-age=999"
      }, ["OK"]]
    }
    m = HanamiForceSSL::Middleware.new(inner)
    _, headers, _ = m.call(ssl_env)
    assert_equal "max-age=999", headers["strict-transport-security"]
  end

  # G2: HSTS applied even on excluded path's SSL response
  def test_hsts_applied_on_excluded_path_ssl_response
    m = middleware(redirect: { exclude: ->(req) { req.path == "/up" } })
    _, headers, _ = m.call(ssl_env("/up"))
    assert headers["strict-transport-security"], "HSTS must be set even on excluded path"
  end

  # G2: no HSTS on non-SSL response (redirect: false, HTTP request)
  def test_no_hsts_on_http_response_with_redirect_false
    m = middleware(redirect: false)
    _, headers, _ = m.call(Rack::MockRequest.env_for("http://example.com/"))
    refute headers["strict-transport-security"]
  end
end

# ─── G2: Secure cookies (Rack-3 array form) ───────────────────────────────────

class SecureCookieTest < Minitest::Test
  def ssl_env(path = "/")
    Rack::MockRequest.env_for("https://example.com#{path}")
  end

  # G2 (crux): Rack-3 array form — each cookie gains "; secure"; result is Array
  def test_secure_cookie_rack3_array_form
    m = HanamiForceSSL::Middleware.new(COOKIE_APP)
    _, headers, _ = m.call(ssl_env)
    cookies = headers["set-cookie"]
    assert_instance_of Array, cookies
    assert_equal 2, cookies.size
    assert_match(/;\s*secure/i, cookies[0])
    assert_match(/;\s*secure/i, cookies[1])
  end

  # G2: already-secure cookie not double-flagged
  def test_already_secure_cookie_not_double_flagged
    m = HanamiForceSSL::Middleware.new(COOKIE_SECURE_APP)
    _, headers, _ = m.call(ssl_env)
    cookies = headers["set-cookie"]
    assert_instance_of Array, cookies
    secure_count = cookies[0].scan(/;\s*secure/i).size
    assert_equal 1, secure_count, "must not double-append '; secure'"
  end

  # G2: String-form Set-Cookie (legacy direct assignment) wrapped to array with secure
  def test_secure_cookie_string_form_becomes_array
    string_cookie_app = ->(env) {
      [200, { "content-type" => "text/html", "content-length" => "2", "set-cookie" => "c=3" }, ["OK"]]
    }
    m = HanamiForceSSL::Middleware.new(string_cookie_app)
    _, headers, _ = m.call(ssl_env)
    cookies = headers["set-cookie"]
    assert_instance_of Array, cookies
    assert_match(/;\s*secure/i, cookies[0])
  end

  # G2: no cookies → no set-cookie header touched
  def test_no_cookies_unchanged
    m = HanamiForceSSL::Middleware.new(OK_APP)
    _, headers, _ = m.call(ssl_env)
    refute headers["set-cookie"]
  end

  # G2: secure cookies NOT applied on excluded path (even on SSL)
  def test_secure_cookies_not_applied_on_excluded_path
    m = HanamiForceSSL::Middleware.new(
      COOKIE_APP,
      redirect: { exclude: ->(req) { req.path == "/up" } }
    )
    _, headers, _ = m.call(ssl_env("/up"))
    cookies = headers["set-cookie"]
    refute_match(/;\s*secure/i, cookies[0])
    refute_match(/;\s*secure/i, cookies[1])
  end

  # G2: secure_cookies: false disables cookie flagging
  def test_secure_cookies_false_disables_flagging
    m = HanamiForceSSL::Middleware.new(COOKIE_APP, secure_cookies: false)
    _, headers, _ = m.call(ssl_env)
    cookies = headers["set-cookie"]
    refute_match(/;\s*secure/i, cookies[0])
  end

  # G2: no cookie flagging on HTTP (non-SSL) responses
  def test_no_secure_cookie_on_http_response
    m = HanamiForceSSL::Middleware.new(COOKIE_APP, redirect: false)
    env = Rack::MockRequest.env_for("http://example.com/")
    _, headers, _ = m.call(env)
    cookies = headers["set-cookie"]
    refute_match(/;\s*secure/i, Array(cookies).first.to_s)
  end
end

# ─── G2: assume_ssl ───────────────────────────────────────────────────────────

class AssumeSslTest < Minitest::Test
  # G2: assume_ssl: true on HTTP → no redirect; treated as SSL
  def test_assume_ssl_no_redirect_on_http
    m = HanamiForceSSL::Middleware.new(OK_APP, assume_ssl: true)
    env = Rack::MockRequest.env_for("http://example.com/")
    status, _, _ = m.call(env)
    assert_equal 200, status
  end

  # G2: assume_ssl: true → HSTS applied
  def test_assume_ssl_hsts_applied
    m = HanamiForceSSL::Middleware.new(OK_APP, assume_ssl: true)
    env = Rack::MockRequest.env_for("http://example.com/")
    _, headers, _ = m.call(env)
    assert headers["strict-transport-security"], "HSTS must be set with assume_ssl"
  end

  # G2: assume_ssl: true → secure cookies applied
  def test_assume_ssl_secure_cookies_applied
    m = HanamiForceSSL::Middleware.new(COOKIE_APP, assume_ssl: true)
    env = Rack::MockRequest.env_for("http://example.com/")
    _, headers, _ = m.call(env)
    cookies = headers["set-cookie"]
    assert_instance_of Array, cookies
    assert_match(/;\s*secure/i, cookies[0])
  end

  # G2: assume_ssl sets expected env vars
  def test_assume_ssl_sets_env_vars
    received_env = nil
    capture_app  = ->(env) { received_env = env; [200, { "content-type" => "text/html", "content-length" => "2" }, ["OK"]] }
    m = HanamiForceSSL::Middleware.new(capture_app, assume_ssl: true)
    m.call(Rack::MockRequest.env_for("http://example.com/"))
    assert_equal "on",    received_env["HTTPS"]
    assert_equal "443",   received_env["HTTP_X_FORWARDED_PORT"]
    assert_equal "https", received_env["HTTP_X_FORWARDED_PROTO"]
    assert_equal "https", received_env["rack.url_scheme"]
  end
end

# ─── G2: exclude ──────────────────────────────────────────────────────────────

class ExcludeTest < Minitest::Test
  UP_EXCLUDE = ->(req) { req.path == "/up" }

  def middleware
    HanamiForceSSL::Middleware.new(OK_APP, redirect: { exclude: UP_EXCLUDE })
  end

  # G2: excluded HTTP path → no redirect
  def test_excluded_http_path_not_redirected
    env = Rack::MockRequest.env_for("http://example.com/up")
    status, _, _ = middleware.call(env)
    assert_equal 200, status
  end

  # G2: non-excluded HTTP path → redirect
  def test_non_excluded_http_path_redirected
    env = Rack::MockRequest.env_for("http://example.com/other")
    status, _, _ = middleware.call(env)
    assert_equal 301, status
  end
end

# ─── G2: Rack::Lint conformance ───────────────────────────────────────────────

class LintConformanceTest < Minitest::Test
  # G2: Rack::Lint passes on HTTPS pass-through path
  def test_rack_lint_https_pass_through
    linted = Rack::Lint.new(HanamiForceSSL::Middleware.new(OK_APP))
    assert_silent { Rack::MockRequest.new(linted).get("https://example.com/") }
  end

  # G2: Rack::Lint passes on HTTP redirect path
  def test_rack_lint_http_redirect
    linted = Rack::Lint.new(HanamiForceSSL::Middleware.new(OK_APP))
    assert_silent { Rack::MockRequest.new(linted).get("http://example.com/") }
  end

  # G2: all response header keys are lowercase on SSL pass-through
  def test_ssl_response_headers_lowercase
    m = HanamiForceSSL::Middleware.new(OK_APP)
    _, headers, _ = m.call(Rack::MockRequest.env_for("https://example.com/"))
    headers.each_key do |k|
      assert_equal k, k.downcase, "header #{k.inspect} must be lowercase"
    end
  end

  # G2: all response header keys are lowercase on redirect
  def test_redirect_response_headers_lowercase
    m = HanamiForceSSL::Middleware.new(OK_APP)
    _, headers, _ = m.call(Rack::MockRequest.env_for("http://example.com/"))
    headers.each_key do |k|
      assert_equal k, k.downcase, "header #{k.inspect} must be lowercase"
    end
  end
end
