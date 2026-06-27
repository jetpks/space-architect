# frozen_string_literal: true

require_relative "test_helper"

class EndpointLivenessTest < Minitest::Test
  def endpoint
    HanamiHealthcheck::Endpoint.new
  end

  # G2(a): no checks → always 200
  def test_liveness_returns_200
    status, _, _ = endpoint.call(Rack::MockRequest.env_for("/up"))
    assert_equal 200, status
  end

  def test_liveness_html_body_contains_up
    _, _, body = endpoint.call(Rack::MockRequest.env_for("/up"))
    assert_includes body.first, "up"
  end

  def test_liveness_html_content_type
    _, headers, _ = endpoint.call(Rack::MockRequest.env_for("/up"))
    assert_equal "text/html", headers["content-type"]
  end
end

class EndpointReadinessTest < Minitest::Test
  def env(accept: nil)
    opts = {}
    opts["HTTP_ACCEPT"] = accept if accept
    Rack::MockRequest.env_for("/up", opts)
  end

  # G2(b): all truthy checks → 200
  def test_readiness_pass_returns_200
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { true }, -> { 42 }])
    status, _, _ = ep.call(env)
    assert_equal 200, status
  end

  # G2(c): falsy check → 503
  def test_readiness_fail_returns_503
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { false }])
    status, _, _ = ep.call(env)
    assert_equal 503, status
  end

  def test_readiness_fail_nil_returns_503
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { nil }])
    status, _, _ = ep.call(env)
    assert_equal 503, status
  end

  # G2(d): raising check → 503, exception NOT propagated
  def test_readiness_raise_returns_503
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { raise "boom" }])
    status, _, _ = ep.call(env)
    assert_equal 503, status
  end

  def test_readiness_raise_does_not_escape_call
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { raise RuntimeError, "leaked" }])
    assert_silent { ep.call(env) }
  end

  # G2(e): content negotiation — JSON up
  def test_json_accept_up_body
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { true }])
    _, _, body = ep.call(env(accept: "application/json"))
    assert_equal '{"status":"up"}', body.first
  end

  # G2(e): content negotiation — JSON down
  def test_json_accept_down_body
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { false }])
    _, _, body = ep.call(env(accept: "application/json"))
    assert_equal '{"status":"down"}', body.first
  end

  # G2(e): content negotiation — HTML green (up)
  def test_html_up_body_green
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { true }])
    _, _, body = ep.call(env)
    assert_includes body.first, "#4ade80"
  end

  # G2(e): content negotiation — HTML red (down)
  def test_html_down_body_red
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { false }])
    _, _, body = ep.call(env)
    assert_includes body.first, "#f87171"
  end

  # G2(f): Rack 3 — lowercase header keys
  def test_lowercase_header_keys
    ep = HanamiHealthcheck::Endpoint.new
    _, headers, _ = ep.call(env)
    headers.each_key { |k| assert_equal k, k.downcase, "header key #{k.inspect} must be lowercase" }
  end

  # G2(f): Rack 3 — body responds to #each
  def test_body_responds_to_each
    _, _, body = HanamiHealthcheck::Endpoint.new.call(env)
    assert_respond_to body, :each
  end

  # G2(f): Rack::Lint round-trip does not raise
  def test_rack_lint_conformance
    linted = Rack::Lint.new(HanamiHealthcheck::Endpoint.new)
    assert_silent { Rack::MockRequest.new(linted).get("/up") }
  end

  # JSON content-type header
  def test_json_content_type_header
    ep = HanamiHealthcheck::Endpoint.new
    _, headers, _ = ep.call(env(accept: "application/json"))
    assert_equal "application/json", headers["content-type"]
  end

  # JSON status on down
  def test_json_accept_down_status
    ep = HanamiHealthcheck::Endpoint.new(checks: [-> { false }])
    status, _, _ = ep.call(env(accept: "application/json"))
    assert_equal 503, status
  end
end
