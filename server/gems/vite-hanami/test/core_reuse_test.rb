# frozen_string_literal: true

require_relative "test_helper"

class CoreReuseTest < Minitest::Test
  # G4 — ViteRuby::DevServerProxy is NOT redefined; constant aliases vite_ruby's class
  def test_dev_server_proxy_is_vite_ruby_class
    assert_same ViteRuby::DevServerProxy, ViteHanami::DevServerProxy
    assert_equal Rack::Proxy, ViteRuby::DevServerProxy.superclass
  end

  # G4 — helpers use ViteRuby::Manifest (not self-parsed JSON)
  def test_helpers_use_vite_ruby_manifest_instance
    vite = build_vite
    assert_kind_of ViteRuby::Manifest, vite.manifest
  end

  def test_helpers_resolve_entries_via_manifest
    vite = build_vite
    # Prove the helper calls through to the real manifest (not bypassing it)
    html = ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx", vite: vite)
    # If the manifest were bypassed, paths would not be prefixed with /vite/assets/
    assert_includes html, "/vite/assets/inertia-Cm3cH5UV.js"
  end

  # G6 — require loads cleanly, vite_ruby resolves
  def test_require_loads_cleanly
    assert defined?(ViteRuby),               "ViteRuby must be defined"
    assert defined?(ViteRuby::Manifest),     "ViteRuby::Manifest must be defined"
    assert defined?(ViteRuby::DevServerProxy), "ViteRuby::DevServerProxy must be defined"
    assert defined?(ViteHanami::TagHelpers), "ViteHanami::TagHelpers must be defined"
    assert defined?(ViteHanami::VERSION),    "ViteHanami::VERSION must be defined"
  end

  # G5 — config seam: fixture config/vite.json drives resolution
  def test_fixture_config_drives_resolution
    vite = build_vite
    # Fixture vite.json sets "publicOutputDir": "vite"
    assert_equal "vite", vite.config.public_output_dir
    # Fixture vite.json sets "sourceCodeDir": "app/frontend"
    assert_equal "app/frontend", vite.config.source_code_dir
    # Paths in resolved tags use the fixture's public_output_dir prefix
    html = ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx", vite: vite)
    assert_includes html, "/vite/assets/", "manifest paths must use public_output_dir from fixture"
  end

  # G5 — injecting a different instance (dev_instance) changes output
  def test_instance_injection_changes_mode
    build_html = ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx", vite: build_vite)
    dev_html   = ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx", vite: dev_instance)
    # Build: hashed filename; dev: unhashed dev-server path
    assert_includes build_html, "inertia-Cm3cH5UV.js"
    assert_includes dev_html,   "entrypoints/inertia.tsx"
    refute_equal build_html, dev_html
  end
end
