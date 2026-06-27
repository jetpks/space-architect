# frozen_string_literal: true

require_relative "test_helper"

def build_renderer(component: "TestComp", props: {errors: {}}, url: "/test",
                   version: nil, encrypt_history: false, layout: nil, root_id: "app")
  cfg = InertiaHanami::Config.new
  cfg.version         = version
  cfg.encrypt_history = encrypt_history
  cfg.root_id         = root_id
  cfg.layout          = layout if layout
  InertiaHanami::Renderer.new(component, props, url, config: cfg)
end

# ─── G2: Page-object JSON correctness ─────────────────────────────────────────

class PageObjectTest < Minitest::Test
  # G2: required keys component, props, url, version always present
  def test_page_object_required_keys
    r = build_renderer
    obj = r.page_object
    assert obj.key?(:component), "missing component"
    assert obj.key?(:props),     "missing props"
    assert obj.key?(:url),       "missing url"
    assert obj.key?(:version),   "missing version"
  end

  def test_page_object_component_value
    r = build_renderer(component: "Conversations/Index")
    assert_equal "Conversations/Index", r.page_object[:component]
  end

  def test_page_object_url_value
    r = build_renderer(url: "/conversations?page=2")
    assert_equal "/conversations?page=2", r.page_object[:url]
  end

  def test_page_object_version_null_when_unset
    r = build_renderer(version: nil)
    assert_nil r.page_object[:version]
  end

  def test_page_object_version_set
    r = build_renderer(version: "abc123")
    assert_equal "abc123", r.page_object[:version]
  end

  # G2: errors always present in props (always_include_errors_hash parity)
  def test_props_always_contains_errors_key
    r = build_renderer(props: {errors: {}})
    assert r.page_object[:props].key?(:errors), "props must always have errors key"
  end

  def test_props_errors_empty_when_no_errors
    r = build_renderer(props: {errors: {}})
    assert_equal({}, r.page_object[:props][:errors])
  end

  def test_props_errors_with_values
    r = build_renderer(props: {errors: {email: "invalid"}})
    assert_equal({email: "invalid"}, r.page_object[:props][:errors])
  end

  # G2: encryptHistory present ONLY when true; absent when false
  def test_encrypt_history_absent_when_false
    r = build_renderer(encrypt_history: false)
    refute r.page_object.key?(:encryptHistory),
           "encryptHistory must be absent when false (v3 omit-when-false)"
  end

  def test_encrypt_history_present_and_true_when_configured
    r = build_renderer(encrypt_history: true)
    assert_equal true, r.page_object[:encryptHistory]
  end
end

# ─── G4: XHR response headers ─────────────────────────────────────────────────

class XhrHeadersTest < Minitest::Test
  def renderer
    build_renderer(props: {errors: {}})
  end

  # G4: X-Inertia: true on XHR response
  def test_xhr_x_inertia_header
    _status, headers, _body = renderer.render_xhr
    assert_equal "true", headers["x-inertia"]
  end

  # G4: Vary contains X-Inertia
  def test_xhr_vary_header
    _status, headers, _body = renderer.render_xhr
    assert_match(/X-Inertia/, headers["vary"])
  end

  # G4: content-type application/json
  def test_xhr_content_type
    _status, headers, _body = renderer.render_xhr
    assert_equal "application/json", headers["content-type"]
  end

  # G4: status 200
  def test_xhr_status_200
    status, _headers, _body = renderer.render_xhr
    assert_equal 200, status
  end

  # Body is valid JSON page object
  def test_xhr_body_is_valid_json
    _status, _headers, body = renderer.render_xhr
    parsed = JSON.parse(body.join)
    assert parsed.key?("component")
    assert parsed.key?("props")
    assert parsed.key?("url")
    assert parsed.key?("version")
  end
end

# ─── G3: Script-element initial render (the boot tripwire) ────────────────────

class InitialRenderTest < Minitest::Test
  def renderer(root_id: "app", layout: nil, encrypt_history: false)
    build_renderer(
      component: "Home",
      props: {errors: {}},
      url: "/",
      root_id: root_id,
      layout: layout,
      encrypt_history: encrypt_history
    )
  end

  # G3: <script type="application/json" data-page="app"> element present (any attr order)
  def test_script_element_has_correct_attributes
    _status, _headers, body = renderer.render_initial
    html = body.join
    assert_match(/<script[^>]*data-page="app"[^>]*>/, html, "script must have data-page=app")
    assert_match(/<script[^>]*type="application\/json"[^>]*>/, html, "script must have type=application/json")
  end

  # G3: data-page attribute value is the root id (NOT the JSON)
  def test_data_page_value_is_root_id_not_json
    _status, _headers, body = renderer.render_initial
    html = body.join
    # data-page="app" (root id), not data-page='{...json...}'
    assert_match(/data-page="app"/, html)
    refute_match(/data-page="\{/, html, "data-page must be root-id, not JSON")
  end

  # G3: sibling <div id="app"> mount point
  def test_sibling_div_with_root_id
    _status, _headers, body = renderer.render_initial
    html = body.join
    assert_match(/<div id="app"/, html)
  end

  # G3: JSON is in the script textContent (between tags), not in an attribute
  def test_json_in_script_textcontent
    _status, _headers, body = renderer.render_initial
    html = body.join
    # Extract script content between opening and closing script tags
    match = html.match(/<script[^>]*>(.*?)<\/script>/m)
    assert match, "script element not found"
    parsed = JSON.parse(match[1])
    assert_equal "Home", parsed["component"]
    assert parsed["props"].key?("errors")
  end

  # G3: closing-tag injection prevention — </script> escaped
  def test_closing_script_tag_escaped
    r = build_renderer(
      component: "Safe",
      props: {errors: {}, xss: "</script><script>alert(1)</script>"},
      url: "/"
    )
    _status, _headers, body = r.render_initial
    html = body.join
    refute_match(%r{</script><script>alert}, html, "</script> sequence must be escaped")
    assert_match(/<\/script>/, html, "the ACTUAL closing </script> tag must still appear")
  end

  # G3: configurable root_id
  def test_custom_root_id
    r = renderer(root_id: "inertia")
    _status, _headers, body = r.render_initial
    html = body.join
    assert_match(/data-page="inertia"/, html)
    assert_match(/<div id="inertia"/, html)
  end

  # G3: default layout wraps into full <!DOCTYPE html> doc
  def test_default_layout_wraps_html
    _status, _headers, body = renderer.render_initial
    html = body.join
    assert_match(/<!DOCTYPE html>/i, html)
    assert_match(/<html/, html)
    assert_match(/<body/, html)
  end

  # G3: configured layout seam replaces default
  def test_custom_layout_seam
    custom_layout = ->(body) { "<custom>#{body}</custom>" }
    r = renderer(layout: custom_layout)
    _status, _headers, body = r.render_initial
    html = body.join
    assert_match(/<custom>/, html)
    refute_match(/<!DOCTYPE html>/i, html)
  end

  # G5: XHR vs initial decision — XHR returns JSON, initial returns HTML
  def test_render_initial_returns_html_content_type
    _status, headers, _body = renderer.render_initial
    assert_equal "text/html; charset=utf-8", headers["content-type"]
  end

  # G2: shared props + flash props merged in (renderer accepts them pre-merged)
  def test_shared_and_flash_props_in_page_object
    r = build_renderer(props: {errors: {}, current_user: "alice", notice: "saved"})
    _status, _headers, body = r.render_xhr
    parsed = JSON.parse(body.join)
    assert_equal "alice", parsed["props"]["current_user"]
    assert_equal "saved", parsed["props"]["notice"]
  end
end
