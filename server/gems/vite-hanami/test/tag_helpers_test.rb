# frozen_string_literal: true

require_relative "test_helper"

class TagHelpersTest < Minitest::Test
  # G1 ——————————————————————————————————————————————————————
  # vite_client_tag: dev → client <script>; build → ""

  def test_vite_client_tag_dev
    html = ViteHanami::TagHelpers.vite_client_tag(vite: dev_instance)
    assert_includes html, "@vite/client"
    assert_includes html, 'type="module"'
    assert_includes html, 'crossorigin="anonymous"'
    assert html.start_with?("<script"), "expected <script> tag, got: #{html.inspect}"
    assert html.end_with?("</script>")
  end

  def test_vite_client_tag_build
    html = ViteHanami::TagHelpers.vite_client_tag(vite: build_vite)
    assert_equal "", html
  end

  # G2 ——————————————————————————————————————————————————————
  # vite_react_refresh_tag: dev → preamble <script type="module">; build → ""

  def test_vite_react_refresh_tag_dev
    html = ViteHanami::TagHelpers.vite_react_refresh_tag(vite: dev_instance)
    assert_includes html, "<script type=\"module\">"
    assert_includes html, "RefreshRuntime.injectIntoGlobalHook(window)"
    assert_includes html, "window.__vite_plugin_react_preamble_installed__ = true"
    assert_includes html, "</script>"
    # Preamble JS contains @react-refresh — emitted as-is, not HTML-escaped
    assert_includes html, "@react-refresh"
  end

  def test_vite_react_refresh_tag_build
    html = ViteHanami::TagHelpers.vite_react_refresh_tag(vite: build_vite)
    assert_equal "", html
  end

  # G3 (CRUX) ———————————————————————————————————————————————
  # vite_typescript_tag "inertia.tsx": build → hashed script + modulepreload + css;
  #                                    dev → dev-server script only

  def test_vite_typescript_tag_build
    html = ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx", vite: build_vite)

    # Entry script — hashed filename from manifest fixture
    assert_includes html, "/vite/assets/inertia-Cm3cH5UV.js"
    assert_includes html, 'type="module"'
    assert_includes html, "crossorigin"

    # Modulepreload for the imported chunk
    assert_includes html, 'rel="modulepreload"'
    assert_includes html, "/vite/assets/chunk-7FE5REVM.js"
    assert_includes html, 'as="script"'

    # Stylesheet link
    assert_includes html, 'rel="stylesheet"'
    assert_includes html, "/vite/assets/inertia-Cm3cH5UV.css"

    # Order: script first, then modulepreload, then stylesheet
    script_pos  = html.index("<script")
    preload_pos = html.index('rel="modulepreload"')
    style_pos   = html.index('rel="stylesheet"')
    assert script_pos < preload_pos, "script must precede modulepreload"
    assert preload_pos < style_pos,  "modulepreload must precede stylesheet"
  end

  def test_vite_typescript_tag_dev
    html = ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx", vite: dev_instance)

    # Dev-server entry path (no hash)
    assert_includes html, "/vite/entrypoints/inertia.tsx"
    assert_includes html, 'type="module"'
    assert_includes html, "crossorigin"

    # No modulepreload or stylesheet in dev (resolve_entries returns empty arrays)
    refute_includes html, "modulepreload"
    refute_includes html, "stylesheet"

    # Exactly one <script> tag
    assert_equal 1, html.scan("<script").size
  end

  def test_vite_typescript_tag_missing_entry_raises
    assert_raises(ViteRuby::MissingEntrypointError) do
      ViteHanami::TagHelpers.vite_typescript_tag("nonexistent.tsx", vite: build_vite)
    end
  end

  # vite_javascript_tag with explicit asset_type: :typescript equals vite_typescript_tag
  def test_vite_javascript_tag_asset_type_typescript
    vite = build_vite
    html_js = ViteHanami::TagHelpers.vite_javascript_tag("inertia.tsx", asset_type: :typescript, vite: vite)
    html_ts = ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx", vite: vite)
    assert_equal html_js, html_ts
  end

  # vite_asset_path returns manifest-resolved browser-ready path
  def test_vite_asset_path
    path = ViteHanami::TagHelpers.vite_asset_path("inertia.tsx", type: :typescript, vite: build_vite)
    assert_equal "/vite/assets/inertia-Cm3cH5UV.js", path
  end

  # Attribute values are HTML-escaped (injection safety)
  def test_vite_client_tag_escapes_attr_values
    vite = dev_instance
    # Override the manifest on the instance to return a src with a double-quote
    manifest = vite.manifest
    manifest.define_singleton_method(:vite_client_src) { '"/evil' }
    html = ViteHanami::TagHelpers.vite_client_tag(vite: vite)
    refute_includes html, '""', "raw double-quote must not appear unescaped in attribute"
    assert_includes html, "&quot;"
  end
end
