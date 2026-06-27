# frozen_string_literal: true

module ViteHanami
  # Plain HTML-string Vite tag helpers. No ActionView, no Hanami view dep.
  # Each helper accepts an optional `vite:` keyword to inject a ViteRuby instance
  # (defaults to ViteRuby.instance). This is the seam for tests and 4c's layout callable.
  #
  # 4c usage example:
  #   layout = -> {
  #     [
  #       ViteHanami::TagHelpers.vite_react_refresh_tag,
  #       ViteHanami::TagHelpers.vite_client_tag,
  #       ViteHanami::TagHelpers.vite_typescript_tag("inertia.tsx"),
  #     ].join("\n")
  #   }
  module TagHelpers
    extend self

    # Renders a `<script>` tag for Vite's HMR client. Dev only; returns "" in build.
    def vite_client_tag(crossorigin: "anonymous", vite: nil)
      vite ||= ViteRuby.instance
      src = vite.manifest.vite_client_src
      return "" unless src
      %(<script src="#{ea(src)}" type="module" crossorigin="#{ea(crossorigin)}"></script>)
    end

    # Renders a `<script type="module">` with the React Refresh preamble. Dev only; returns "" in build.
    def vite_react_refresh_tag(vite: nil)
      vite ||= ViteRuby.instance
      code = vite.manifest.react_preamble_code
      return "" unless code
      "<script type=\"module\">\n#{code}</script>"
    end

    # Renders script + modulepreload + stylesheet tags for the given TypeScript entrypoints.
    def vite_typescript_tag(*names, vite: nil, **opts)
      vite_javascript_tag(*names, asset_type: :typescript, vite: vite, **opts)
    end

    # Renders script + modulepreload + stylesheet tags for the given entrypoints.
    # resolve_entries drives dev-vs-build: in dev, imports/stylesheets are empty arrays.
    def vite_javascript_tag(*names,
        type: "module",
        asset_type: :javascript,
        crossorigin: "anonymous",
        media: "screen",
        skip_preload_tags: false,
        skip_style_tags: false,
        vite: nil)
      vite ||= ViteRuby.instance
      entries = vite.manifest.resolve_entries(*names, type: asset_type)
      tags = []

      entries.fetch(:scripts).each do |src|
        tags << %(<script src="#{ea(src)}" type="#{ea(type)}" crossorigin="#{ea(crossorigin)}"></script>)
      end

      unless skip_preload_tags
        entries.fetch(:imports).each do |href|
          tags << %(<link rel="modulepreload" href="#{ea(href)}" as="script" crossorigin="#{ea(crossorigin)}">)
        end
      end

      unless skip_style_tags
        entries.fetch(:stylesheets).each do |href|
          tags << %(<link rel="stylesheet" href="#{ea(href)}">)
        end
      end

      tags.join("\n")
    end

    # Returns the browser-ready path for a Vite-managed asset (manifest-resolved).
    def vite_asset_path(name, vite: nil, **opts)
      vite ||= ViteRuby.instance
      vite.manifest.path_for(name, **opts)
    end

    # Renders `<link rel="stylesheet">` tags for the given Vite-managed CSS entrypoints.
    def vite_stylesheet_tag(*names, vite: nil, **opts)
      vite ||= ViteRuby.instance
      names.map { |name|
        href = vite.manifest.path_for(name, type: :stylesheet, **opts)
        %(<link rel="stylesheet" href="#{ea(href)}">)
      }.join("\n")
    end

    private

    # HTML attribute value escaper — handles double-quoted attributes only.
    # Script body (preamble code) is JS, NOT passed through this; emitted as-is.
    def ea(value)
      value.to_s
        .gsub("&", "&amp;")
        .gsub('"', "&quot;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
    end
  end
end
