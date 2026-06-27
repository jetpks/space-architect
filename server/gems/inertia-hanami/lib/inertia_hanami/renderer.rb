# frozen_string_literal: true

require "json"

module InertiaHanami
  # Builds the Inertia page object and serializes it to XHR JSON or initial HTML.
  #
  # Page object shape (inertia_rails renderer.rb:133-150):
  #   { component:, props:, url:, version: } + encryptHistory: true only when configured.
  #   props always contains an errors key (inertia_rails controller.rb:127-152).
  #
  # Initial render uses the script-element form (G2):
  #   <script data-page="app" type="application/json">…JSON…</script>
  #   <div id="app"></div>
  # Confirmed against @inertiajs/core/dist/index.js:699:
  #   document.querySelector(`script[data-page="${id}"][type="application/json"]`)
  #   returns null for the div data-page attribute form — do NOT use that form.
  class Renderer
    def initialize(component, props, url, config:)
      @component = component
      @props     = props
      @url       = url
      @config    = config
    end

    # Returns [status, headers, body] for an Inertia XHR response.
    # inertia_rails renderer.rb:47-53
    def render_xhr
      headers = {
        "content-type" => "application/json",
        "x-inertia"    => "true",
        "vary"         => "X-Inertia"
      }
      [200, headers, [page_json]]
    end

    # Returns [status, headers, body] for an initial (non-Inertia) full-page response.
    # Wraps the inertia body via the configured layout seam (G3).
    def render_initial
      html = @config.layout.call(inertia_body)
      [200, {"content-type" => "text/html; charset=utf-8"}, [html]]
    end

    # The page object hash sent to the client.
    # inertia_rails renderer.rb:133-150; controller.rb:127-152
    def page_object
      obj = {
        component: @component,
        props:     @props,
        url:       @url,
        version:   @config.resolved_version
      }
      # v3 omit-when-false behavior: encryptHistory present ONLY when true
      obj[:encryptHistory] = true if @config.encrypt_history
      obj
    end

    private

    # JSON-serialized page object with </script> injection prevention.
    # inertia_rails helper.rb:40 uses .html_safe which triggers AS escaping;
    # we replicate by replacing </ → <\/ which prevents closing-tag injection.
    def page_json
      JSON.generate(page_object).gsub("</", "<\\/")
    end

    # Script-element + root div (G2/G3).
    # inertia_rails helper.rb:34-46:
    #   tag.script(page.to_json.html_safe, 'data-page': id, type: 'application/json')
    #   tag.div(id: id)
    def inertia_body
      root_id = @config.root_id
      <<~HTML.chomp
        <script data-page="#{root_id}" type="application/json">#{page_json}</script>
        <div id="#{root_id}"></div>
      HTML
    end
  end
end
