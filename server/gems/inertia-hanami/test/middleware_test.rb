# frozen_string_literal: true

require_relative "test_helper"

# Stub downstream app — returns a configurable response without touching the session.
class StubApp
  def initialize(status: 200, mutate_session: nil)
    @status         = status
    @mutate_session = mutate_session
  end

  def call(env)
    @mutate_session&.call(env["rack.session"])
    [@status, {"content-type" => "text/html"}, ["OK"]]
  end
end

def build_config(version: nil)
  cfg = InertiaHanami::Config.new
  cfg.version = version
  cfg
end

# ─── G1a: version-409 + X-Inertia-Location + flash reflash (GET only) ───────

class VersionMismatchTest < Minitest::Test
  include InertiaConfigReset

  def middleware(version: "v2")
    cfg = build_config(version: version)
    InertiaHanami::Middleware.new(StubApp.new, config: cfg)
  end

  # G1(a): Inertia GET + version mismatch → 409 + X-Inertia-Location
  def test_stale_inertia_get_returns_409
    env = Rack::MockRequest.env_for("http://example.com/foo?q=1",
                                    "HTTP_X_INERTIA"         => "true",
                                    "HTTP_X_INERTIA_VERSION" => "v1")
    env["rack.session"] = {}
    status, headers, _body = middleware.call(env)
    assert_equal 409, status
    assert_equal "http://example.com/foo?q=1", headers["x-inertia-location"]
  end

  # G1(a): flash is reflashed (preserved) after 409
  def test_stale_inertia_get_reflashes_flash
    # The stub app deletes _flash to simulate a Hanami action sweeping the flash
    sweeping_app = StubApp.new(mutate_session: ->(s) { s&.delete("_flash") })
    cfg = build_config(version: "v2")
    m = InertiaHanami::Middleware.new(sweeping_app, config: cfg)

    env = Rack::MockRequest.env_for("http://example.com/",
                                    "HTTP_X_INERTIA"         => "true",
                                    "HTTP_X_INERTIA_VERSION" => "v1")
    env["rack.session"] = {"_flash" => {"notice" => "hello"}}
    status, _headers, _body = m.call(env)

    assert_equal 409, status
    assert_equal({"notice" => "hello"}, env["rack.session"]["_flash"],
                 "flash must be reflashed (restored) after 409")
  end

  # G1(b): matching version → pass-through (no 409)
  def test_matching_version_passes_through
    env = Rack::MockRequest.env_for("http://example.com/",
                                    "HTTP_X_INERTIA"         => "true",
                                    "HTTP_X_INERTIA_VERSION" => "v2")
    env["rack.session"] = {}
    status, _headers, _body = middleware.call(env)
    assert_equal 200, status
  end

  # G1(b): no version configured → always pass-through
  def test_no_version_configured_passes_through
    cfg = build_config(version: nil)
    m = InertiaHanami::Middleware.new(StubApp.new, config: cfg)
    env = Rack::MockRequest.env_for("http://example.com/",
                                    "HTTP_X_INERTIA"         => "true",
                                    "HTTP_X_INERTIA_VERSION" => "anything")
    env["rack.session"] = {}
    status, _headers, _body = m.call(env)
    assert_equal 200, status
  end

  # G1(c): version mismatch on POST → no 409
  def test_stale_inertia_post_no_409
    env = Rack::MockRequest.env_for("http://example.com/",
                                    "REQUEST_METHOD"         => "POST",
                                    "HTTP_X_INERTIA"         => "true",
                                    "HTTP_X_INERTIA_VERSION" => "v1")
    env["rack.session"] = {}
    status, _headers, _body = middleware.call(env)
    assert_equal 200, status
  end

  # G1(c): version mismatch on PUT → no 409
  def test_stale_inertia_put_no_409
    env = Rack::MockRequest.env_for("http://example.com/",
                                    "REQUEST_METHOD"         => "PUT",
                                    "HTTP_X_INERTIA"         => "true",
                                    "HTTP_X_INERTIA_VERSION" => "v1")
    env["rack.session"] = {}
    status, _headers, _body = middleware.call(env)
    assert_equal 200, status
  end
end

# ─── G1d: 303 coercion ────────────────────────────────────────────────────────

class CoercionTest < Minitest::Test
  include InertiaConfigReset

  def middleware(method:, downstream_status:)
    cfg = build_config(version: nil)
    InertiaHanami::Middleware.new(
      StubApp.new(status: downstream_status),
      config: cfg
    )
  end

  # G1(d): Inertia PUT + 302 → 303
  def test_302_put_coerced_to_303
    m = middleware(method: "PUT", downstream_status: 302)
    env = Rack::MockRequest.env_for("/", "REQUEST_METHOD" => "PUT", "HTTP_X_INERTIA" => "true")
    env["rack.session"] = {}
    status, _h, _b = m.call(env)
    assert_equal 303, status
  end

  # G1(d): Inertia PATCH + 302 → 303
  def test_302_patch_coerced_to_303
    m = middleware(method: "PATCH", downstream_status: 302)
    env = Rack::MockRequest.env_for("/", "REQUEST_METHOD" => "PATCH", "HTTP_X_INERTIA" => "true")
    env["rack.session"] = {}
    status, _h, _b = m.call(env)
    assert_equal 303, status
  end

  # G1(d): Inertia DELETE + 302 → 303
  def test_302_delete_coerced_to_303
    m = middleware(method: "DELETE", downstream_status: 302)
    env = Rack::MockRequest.env_for("/", "REQUEST_METHOD" => "DELETE", "HTTP_X_INERTIA" => "true")
    env["rack.session"] = {}
    status, _h, _b = m.call(env)
    assert_equal 303, status
  end

  # G1(d): Inertia GET + 302 → untouched
  def test_302_get_not_coerced
    m = middleware(method: "GET", downstream_status: 302)
    env = Rack::MockRequest.env_for("/", "REQUEST_METHOD" => "GET", "HTTP_X_INERTIA" => "true")
    env["rack.session"] = {}
    status, _h, _b = m.call(env)
    assert_equal 302, status
  end

  # G1(d): Inertia POST + 302 → untouched
  def test_302_post_not_coerced
    m = middleware(method: "POST", downstream_status: 302)
    env = Rack::MockRequest.env_for("/", "REQUEST_METHOD" => "POST", "HTTP_X_INERTIA" => "true")
    env["rack.session"] = {}
    status, _h, _b = m.call(env)
    assert_equal 302, status
  end
end

# ─── G1e: session cleanup on non-redirect ─────────────────────────────────────

class SessionCleanupTest < Minitest::Test
  include InertiaConfigReset

  def middleware
    InertiaHanami::Middleware.new(StubApp.new(status: 200), config: build_config)
  end

  # G1(e): inertia_errors deleted on non-redirect response
  def test_inertia_errors_cleared_on_non_redirect
    env = Rack::MockRequest.env_for("/", "HTTP_X_INERTIA" => "true")
    env["rack.session"] = {"inertia_errors" => {"name" => "required"}}
    middleware.call(env)
    refute env["rack.session"].key?("inertia_errors"),
           "inertia_errors must be cleared on non-redirect response"
  end

  # inertia_errors kept on redirect (302)
  def test_inertia_errors_kept_on_redirect
    m = InertiaHanami::Middleware.new(StubApp.new(status: 302), config: build_config)
    env = Rack::MockRequest.env_for("/", "HTTP_X_INERTIA" => "true")
    env["rack.session"] = {"inertia_errors" => {"name" => "required"}}
    m.call(env)
    assert env["rack.session"].key?("inertia_errors"),
           "inertia_errors must be preserved on redirect response"
  end

  # inertia_clear_history deleted on non-redirect
  def test_inertia_clear_history_cleared_on_non_redirect
    env = Rack::MockRequest.env_for("/", "HTTP_X_INERTIA" => "true")
    env["rack.session"] = {"inertia_clear_history" => true}
    middleware.call(env)
    refute env["rack.session"].key?("inertia_clear_history")
  end

  # No session → no error raised (guard on session loaded)
  def test_no_session_no_error
    env = Rack::MockRequest.env_for("/", "HTTP_X_INERTIA" => "true")
    # env["rack.session"] is nil — no session middleware
    assert_silent { middleware.call(env) }
  end
end

# ─── G1f: XSRF→CSRF bridge ────────────────────────────────────────────────────

class XsrfBridgeTest < Minitest::Test
  include InertiaConfigReset

  def middleware
    InertiaHanami::Middleware.new(StubApp.new, config: build_config)
  end

  # G1(f): HTTP_X_XSRF_TOKEN present + HTTP_X_CSRF_TOKEN absent → copied
  def test_xsrf_copied_when_csrf_absent
    captured_env = nil
    app = ->(env) { captured_env = env; [200, {}, []] }
    m = InertiaHanami::Middleware.new(app, config: build_config)

    env = Rack::MockRequest.env_for("/")
    env["HTTP_X_XSRF_TOKEN"] = "my-xsrf-token"

    m.call(env)
    assert_equal "my-xsrf-token", captured_env["HTTP_X_CSRF_TOKEN"]
  end

  # HTTP_X_CSRF_TOKEN already present → not overwritten
  def test_xsrf_not_copied_when_csrf_present
    captured_env = nil
    app = ->(env) { captured_env = env; [200, {}, []] }
    m = InertiaHanami::Middleware.new(app, config: build_config)

    env = Rack::MockRequest.env_for("/")
    env["HTTP_X_XSRF_TOKEN"] = "xsrf-token"
    env["HTTP_X_CSRF_TOKEN"] = "original-csrf-token"

    m.call(env)
    assert_equal "original-csrf-token", captured_env["HTTP_X_CSRF_TOKEN"]
  end
end

# ─── G1g-pre: XSRF-TOKEN cookie ─────────────────────────────────────────────

class XsrfCookieTest < Minitest::Test
  include InertiaConfigReset

  def middleware
    InertiaHanami::Middleware.new(StubApp.new, config: build_config)
  end

  def xsrf_cookie(headers)
    set_cookie = headers["set-cookie"]
    return nil unless set_cookie
    cookies = Array(set_cookie)
    cookies.find { |c| c.start_with?("XSRF-TOKEN=") }
  end

  # Token present (string key) → XSRF-TOKEN cookie set
  def test_xsrf_cookie_set_when_session_has_string_key_token
    env = Rack::MockRequest.env_for("http://example.com/")
    env["rack.session"] = {"_csrf_token" => "tok-string-123"}
    _, headers, _ = middleware.call(env)
    cookie = xsrf_cookie(headers)
    refute_nil cookie, "XSRF-TOKEN cookie must be present"
    assert_includes cookie, "tok-string-123"
    assert_includes cookie.downcase, "path=/"
    assert_includes cookie.downcase, "samesite=lax"
    refute_includes cookie.downcase, "httponly"
  end

  # Token present (symbol key) → XSRF-TOKEN cookie set
  def test_xsrf_cookie_set_when_session_has_symbol_key_token
    env = Rack::MockRequest.env_for("http://example.com/")
    env["rack.session"] = {_csrf_token: "tok-sym-456"}
    _, headers, _ = middleware.call(env)
    cookie = xsrf_cookie(headers)
    refute_nil cookie, "XSRF-TOKEN cookie must be present for symbol-keyed session"
    assert_includes cookie, "tok-sym-456"
    assert_includes cookie.downcase, "samesite=lax"
    refute_includes cookie.downcase, "httponly"
  end

  # No token in session → no XSRF-TOKEN cookie
  def test_no_xsrf_cookie_when_session_has_no_token
    env = Rack::MockRequest.env_for("http://example.com/")
    env["rack.session"] = {}
    _, headers, _ = middleware.call(env)
    refute xsrf_cookie(headers), "XSRF-TOKEN cookie must NOT be set when session has no token"
  end

  # XSRF-TOKEN cookie does not clobber existing Set-Cookie (e.g. _hanakai_session)
  def test_xsrf_cookie_does_not_clobber_existing_set_cookie
    stub_with_session_cookie = lambda do |env|
      [200, {"set-cookie" => "_hanakai_session=abc; path=/; httponly"}, ["OK"]]
    end
    m = InertiaHanami::Middleware.new(stub_with_session_cookie, config: build_config)
    env = Rack::MockRequest.env_for("http://example.com/")
    env["rack.session"] = {"_csrf_token" => "tok-noclobber"}
    _, headers, _ = m.call(env)
    cookies = Array(headers["set-cookie"])
    assert cookies.any? { |c| c.start_with?("_hanakai_session=") },
           "_hanakai_session cookie must still be present"
    assert cookies.any? { |c| c.start_with?("XSRF-TOKEN=") },
           "XSRF-TOKEN cookie must be appended"
  end

  # XSRF-TOKEN rides redirect responses (302) as well
  def test_xsrf_cookie_set_on_redirect
    m = InertiaHanami::Middleware.new(StubApp.new(status: 302), config: build_config)
    env = Rack::MockRequest.env_for("http://example.com/")
    env["rack.session"] = {"_csrf_token" => "tok-redir"}
    _, headers, _ = m.call(env)
    cookie = xsrf_cookie(headers)
    refute_nil cookie, "XSRF-TOKEN cookie must be set even on redirect responses"
    assert_includes cookie, "tok-redir"
  end
end

# ─── G1g: non-Inertia request untouched ──────────────────────────────────────

class NonInertiaRequestTest < Minitest::Test
  include InertiaConfigReset

  # G1(g): no X-Inertia header → no version/409 logic, passes through unchanged
  def test_non_inertia_request_passes_through
    cfg = build_config(version: "v2")
    m = InertiaHanami::Middleware.new(StubApp.new(status: 200), config: cfg)
    env = Rack::MockRequest.env_for("http://example.com/foo",
                                    "HTTP_X_INERTIA_VERSION" => "v1")
    env["rack.session"] = {}
    status, _h, _b = m.call(env)
    assert_equal 200, status
  end

  # Non-Inertia redirect → no 303 coercion
  def test_non_inertia_302_not_coerced
    cfg = build_config(version: nil)
    m = InertiaHanami::Middleware.new(StubApp.new(status: 302), config: cfg)
    env = Rack::MockRequest.env_for("/", "REQUEST_METHOD" => "PUT")
    env["rack.session"] = {}
    status, _h, _b = m.call(env)
    assert_equal 302, status
  end
end
