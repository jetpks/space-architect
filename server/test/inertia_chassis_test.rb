# frozen_string_literal: true

require_relative "test_helper"
require_relative "actions/action_test_helper"
require "rack/mock"
require "json"

# G0: boot smoke — /up → 200
class InertiaChassisBootTest < Minitest::Test
  include ActionTestHelper

  def test_up_returns_200
    status, _, _ = get("/up")
    assert_equal 200, status
  end
end

# G1-G7: initial-render HTML structure via the real configured layout.
# Calls Space::Server::App.start(:inertia) to load the provider (idempotent; noops if already started).
class InertiaChassisLayoutTest < Minitest::Test
  def setup
    # config/providers/inertia.rb is loaded lazily; start it so InertiaHanami.configure runs.
    Space::Server::App.start(:inertia)
    super
  end

  def vite_instance
    Space::Server::App["vite"]
  end

  # Render the configured layout with dev-mode vite: stub dev_server_running? → true
  # so all three tag helpers emit real HTML without a committed manifest or live Vite process.
  def render_layout(inertia_body = nil)
    inertia_body ||= default_inertia_body
    html = nil
    vite_instance.stub(:dev_server_running?, true) do
      html = InertiaHanami.configuration.layout.call(inertia_body)
    end
    html
  end

  def default_inertia_body
    page = JSON.generate(
      component: "Test/Component",
      props: { errors: {} },
      url: "/",
      version: nil,
      encryptHistory: true
    )
    %(<script data-page="app" type="application/json">#{page}</script>\n<div id="app"></div>)
  end

  # G1: DOCTYPE + dark class
  def test_doctype_and_dark_class
    html = render_layout
    assert html.start_with?("<!DOCTYPE html>"), "must start with DOCTYPE, got: #{html[0, 30].inspect}"
    assert_includes html, '<html class="dark">'
  end

  # G2: title has data-inertia attribute
  def test_title_has_data_inertia_attribute
    html = render_layout
    assert_includes html, "<title data-inertia>"
    assert_includes html, "Chat Share"
    refute_includes html, "content_for"
  end

  # G3: four meta tags present
  def test_four_meta_tags_present
    html = render_layout
    assert_includes html, 'name="viewport"'
    assert_includes html, 'name="apple-mobile-web-app-capable"'
    assert_includes html, 'name="application-name"'
    assert_includes html, 'name="mobile-web-app-capable"'
  end

  # G4: three icon links present
  def test_three_icon_links_present
    html = render_layout
    assert_includes html, '<link rel="icon" href="/icon.png" type="image/png">'
    assert_includes html, '<link rel="icon" href="/icon.svg" type="image/svg+xml">'
    assert_includes html, '<link rel="apple-touch-icon" href="/icon.png">'
  end

  # G5: three Vite tags present and in order (react_refresh → client → typescript)
  def test_three_vite_tags_in_order
    html = render_layout
    # dev-mode tag helpers emit these substrings when dev_server_running? is true:
    assert_includes html, "@react-refresh"   # from react_preamble_code inside react_refresh_tag
    assert_includes html, "@vite/client"     # from vite_client_src inside vite_client_tag
    assert_includes html, "inertia.tsx"      # entry script path from vite_typescript_tag

    refresh_pos = html.index("@react-refresh")
    client_pos  = html.index("@vite/client")
    tsx_pos     = html.index("inertia.tsx")
    assert refresh_pos < client_pos, "react_refresh_tag must precede vite_client_tag"
    assert client_pos  < tsx_pos,    "vite_client_tag must precede vite_typescript_tag"
  end

  # A2: no CSP meta (omitted per arbitration)
  def test_no_csp_meta
    html = render_layout
    refute_includes html.downcase, "content-security-policy"
    refute_includes html, "csp_meta"
  end

  # A1: no CSRF meta (deferred to 4c-3)
  def test_no_csrf_meta
    html = render_layout
    refute_includes html, 'name="csrf-token"'
    refute_includes html, "csrf_meta"
  end

  # F2/G3: inertia_body lands in <body>; script element + div#app present
  def test_inertia_body_in_body_tag
    html = render_layout
    assert_includes html, "<body>"
    assert_includes html, 'data-page="app"'
    assert_includes html, 'type="application/json"'
    assert_includes html, '<div id="app">'
  end

  # §2.3: vite instance root must point to architect/config/vite.json
  def test_vite_instance_is_architect_rooted
    vite = vite_instance
    root = vite.config.root
    assert root.join("config/vite.json").exist?,
      "architect vite instance must find config/vite.json at #{root.join('config/vite.json')}"
  end

  # InertiaHanami config values installed by the provider
  def test_inertia_config_encrypt_history_true
    assert_equal true, InertiaHanami.configuration.encrypt_history
  end

  def test_inertia_config_root_id_app
    assert_equal "app", InertiaHanami.configuration.root_id
  end

  def test_inertia_config_version_callable
    assert InertiaHanami.configuration.version.respond_to?(:call),
      "version must be a callable (digest computed per request)"
  end
end
