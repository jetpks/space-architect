# frozen_string_literal: true

require_relative "test_helper"
require "hanami/action"
require "hanami/action/session"

# ─── Test action definitions ──────────────────────────────────────────────────

# Basic render action — no session required for pure rendering of shared props.
class RenderAction < Hanami::Action
  include Hanami::Action::Session
  include InertiaHanami::Action

  def handle(req, res)
    render_inertia(req, res, "Conversations/Index", props: {title: "hello"})
  end
end

# Action with shared props configured globally.
class SharedPropsAction < Hanami::Action
  include Hanami::Action::Session
  include InertiaHanami::Action

  def handle(req, res)
    render_inertia(req, res, "Dashboard", props: {})
  end
end

# Action that triggers a redirect with errors stashed in session.
class RedirectWithErrorsAction < Hanami::Action
  include Hanami::Action::Session
  include InertiaHanami::Action

  def handle(req, res)
    redirect_inertia(req, res, "/form", errors: {"email" => "is invalid"})
  end
end

# Action that renders, surfaces session errors in props.
class RenderAfterRedirectAction < Hanami::Action
  include Hanami::Action::Session
  include InertiaHanami::Action

  def handle(req, res)
    render_inertia(req, res, "Form", props: {})
  end
end

# ─── Helper: build a pre-seeded rack.session env ─────────────────────────────

def inertia_env(path, session: {}, method: "GET", xhr: false)
  opts = {"REQUEST_METHOD" => method}
  opts["HTTP_X_INERTIA"] = "true" if xhr
  env = Rack::MockRequest.env_for("http://example.com#{path}", opts)
  env["rack.session"] = session
  env
end

# ─── G6a: Initial request → 200 HTML with script element + props ──────────────

class ActionInitialRenderTest < Minitest::Test
  include InertiaConfigReset

  # G6(a): initial request → 200, HTML body with script element + props
  def test_initial_request_returns_html
    action = RenderAction.new
    env    = inertia_env("/conversations")
    status, headers, body = action.call(env)

    assert_equal 200, status
    assert_match("text/html", headers["content-type"] || "")
    html = body.join
    assert_match(/data-page="app"/, html)
    assert_match(/type="application\/json"/, html)
    assert_match(/<div id="app"/, html)
  end

  # G6(a): props are in the initial HTML page object
  def test_initial_render_includes_props
    action = RenderAction.new
    env    = inertia_env("/conversations")
    _status, _headers, body = action.call(env)
    html = body.join

    match = html.match(/<script[^>]*>(.*?)<\/script>/m)
    assert match, "script element not found in initial HTML"
    parsed = JSON.parse(match[1])
    assert_equal "Conversations/Index", parsed["component"]
    assert_equal "hello",              parsed["props"]["title"]
    assert parsed["props"].key?("errors"), "errors key always present"
  end
end

# ─── G6b: Inertia XHR → 200 JSON + X-Inertia: true + Vary ───────────────────

class ActionXhrRenderTest < Minitest::Test
  include InertiaConfigReset

  # G6(b): XHR request → 200 JSON page object + X-Inertia: true + Vary: X-Inertia
  def test_xhr_request_returns_json
    action = RenderAction.new
    env    = inertia_env("/conversations", xhr: true)
    status, headers, _body = action.call(env)

    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]
    assert_equal "true",             headers["x-inertia"]
    assert_match(/X-Inertia/,        headers["vary"])
  end

  # G6(b): XHR body is a valid page object
  def test_xhr_body_is_page_object
    action = RenderAction.new
    env    = inertia_env("/conversations", xhr: true)
    _status, _headers, body = action.call(env)

    parsed = JSON.parse(body.join)
    assert_equal "Conversations/Index", parsed["component"]
    assert parsed.key?("props")
    assert parsed.key?("url")
    assert parsed.key?("version")
  end

  # G5: XHR returns JSON; initial returns HTML — confirmed both ways
  def test_xhr_vs_initial_decision
    action = RenderAction.new

    env_xhr = inertia_env("/", xhr: true)
    _s, headers_xhr, _b = action.call(env_xhr)
    assert_equal "application/json", headers_xhr["content-type"]

    env_init = inertia_env("/")
    _s, headers_init, _b = action.call(env_init)
    assert_match("text/html", headers_init["content-type"])
  end
end

# ─── G6c: Shared props + flash + errors merged ────────────────────────────────

class ActionSharedPropsTest < Minitest::Test
  include InertiaConfigReset

  # G6(c): shared_props hook result merged into props
  def test_shared_props_merged
    InertiaHanami.configure do |c|
      c.shared_props = ->(_req) { {current_user: "bob"} }
    end

    action = SharedPropsAction.new
    env    = inertia_env("/dashboard", xhr: true)
    _status, _headers, body = action.call(env)
    parsed = JSON.parse(body.join)

    assert_equal "bob", parsed["props"]["current_user"]
  end

  # G6(c): flash {notice, alert} from session merged into props
  def test_flash_merged_from_session
    action = SharedPropsAction.new
    env    = inertia_env("/dashboard",
                         session: {"_flash" => {"notice" => "Saved!", "alert" => "Warning"}},
                         xhr: true)
    _status, _headers, body = action.call(env)
    parsed = JSON.parse(body.join)

    assert_equal "Saved!",   parsed["props"]["notice"]
    assert_equal "Warning",  parsed["props"]["alert"]
  end

  # G6(c): errors from session[:inertia_errors] merged into props.errors
  def test_session_errors_merged_into_props
    action = SharedPropsAction.new
    env    = inertia_env("/dashboard",
                         session: {"inertia_errors" => {"name" => "can't be blank"}},
                         xhr: true)
    _status, _headers, body = action.call(env)
    parsed = JSON.parse(body.join)

    assert_equal({"name" => "can't be blank"}, parsed["props"]["errors"])
  end

  # G2: errors key always present even without session errors
  def test_errors_always_present_when_no_errors
    action = SharedPropsAction.new
    env    = inertia_env("/dashboard", session: {}, xhr: true)
    _status, _headers, body = action.call(env)
    parsed = JSON.parse(body.join)

    assert parsed["props"].key?("errors"), "errors key must always be present"
    assert_equal({}, parsed["props"]["errors"])
  end
end

# ─── G6d: Redirect-back-with-errors round-trip ───────────────────────────────

class ActionErrorRoundTripTest < Minitest::Test
  include InertiaConfigReset

  # G6(d): redirect_inertia stashes errors in session; next render surfaces them in props.errors
  def test_redirect_with_errors_surfaces_on_next_render
    shared_session = {}

    # Request 1: redirect action stashes errors
    redirect_action = RedirectWithErrorsAction.new
    env1 = inertia_env("/form", session: shared_session, method: "POST")
    status1, headers1, _body1 = redirect_action.call(env1)

    assert_equal 302,    status1
    assert_match "/form", headers1["location"]
    assert_equal({"email" => "is invalid"}, shared_session["inertia_errors"])

    # Request 2: render action reads errors from session and merges into props
    render_action = RenderAfterRedirectAction.new
    env2 = inertia_env("/form", session: shared_session, xhr: true)
    _status2, _headers2, body2 = render_action.call(env2)

    parsed = JSON.parse(body2.join)
    assert_equal({"email" => "is invalid"}, parsed["props"]["errors"])
  end
end

# ─── G7: gem loads cleanly ────────────────────────────────────────────────────

class GemLoadTest < Minitest::Test
  def test_require_loads_cleanly
    assert defined?(InertiaHanami),             "InertiaHanami module must be defined"
    assert defined?(InertiaHanami::Middleware),  "InertiaHanami::Middleware must be defined"
    assert defined?(InertiaHanami::Renderer),    "InertiaHanami::Renderer must be defined"
    assert defined?(InertiaHanami::Action),      "InertiaHanami::Action must be defined"
    assert defined?(InertiaHanami::Config),      "InertiaHanami::Config must be defined"
  end

  def test_configure_block
    InertiaHanami.reset_configuration!
    InertiaHanami.configure do |c|
      c.version         = "test-v1"
      c.encrypt_history = true
      c.root_id         = "root"
    end
    cfg = InertiaHanami.configuration
    assert_equal "test-v1", cfg.resolved_version
    assert_equal true,      cfg.encrypt_history
    assert_equal "root",    cfg.root_id
    InertiaHanami.reset_configuration!
  end
end
