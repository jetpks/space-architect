# frozen_string_literal: true

module InertiaHanami
  class Config
    # Minimal default layout: wraps the inertia body into a bare HTML document.
    # 4c replaces this seam with the real layout (Vite head tags + csrf meta + dark root).
    MINIMAL_LAYOUT = ->(inertia_body) {
      "<!DOCTYPE html><html><head></head><body>#{inertia_body}</body></html>"
    }

    attr_accessor :version, :shared_props, :layout, :root_id, :encrypt_history

    def initialize
      @version         = nil
      @shared_props    = ->(_req) { {} }
      @layout          = MINIMAL_LAYOUT
      @root_id         = "app"
      @encrypt_history = false
    end

    # Resolves the version — supports String or callable.
    def resolved_version
      v = version
      v.respond_to?(:call) ? v.call : v
    end
  end
end
