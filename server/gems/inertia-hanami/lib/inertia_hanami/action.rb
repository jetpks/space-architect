# frozen_string_literal: true

module InertiaHanami
  # Mixin for Hanami::Action subclasses. Provides render_inertia and redirect_inertia.
  #
  # Usage:
  #   class MyAction < Hanami::Action
  #     include Hanami::Action::Session
  #     include InertiaHanami::Action
  #
  #     def handle(req, res)
  #       render_inertia(req, res, "MyComponent", props: { data: 42 })
  #     end
  #   end
  #
  # Q4a-1 (Hanami::Action lifecycle):
  #   handle(req, res) is the per-request entry point.
  #   req = Hanami::Action::Request (< Rack::Request); res = Hanami::Action::Response (< Rack::Response).
  #   Set response via: res.status = N, res.body = "str", res.set_header("name", "val").
  #   Session via req.session (Hanami::Action::Request::Session, string-keyed wrapper over rack.session).
  #   Flash via req.flash (Hanami::Action::Flash, stored under session["_flash"]).
  #   Both raise MissingSessionError unless Hanami::Action::Session is included.
  module Action
    # Render an Inertia page. Merges shared props + flash + session errors into props,
    # then dispatches to XHR (JSON) or initial (HTML) response via the Renderer.
    #
    # inertia_rails controller.rb:127-168 (shared data merge);
    # renderer.rb:47-53 (XHR); helper.rb:34-46 (initial HTML).
    def render_inertia(req, res, component, props: {})
      config  = InertiaHanami.configuration
      merged  = build_inertia_props(req, config, props)
      url     = build_url(req)
      renderer = Renderer.new(component, merged, url, config: config)

      if inertia_request?(req)
        apply_xhr_response(req, res, renderer)
      else
        apply_initial_response(res, renderer)
      end
    end

    # Stash errors in the session and redirect. The middleware clears inertia_errors
    # on the next non-redirect response; the render action surfaces them via props.errors.
    #
    # inertia_rails controller.rb:170-186 (capture_inertia_session_options)
    def redirect_inertia(req, res, url, errors: nil, status: 302)
      if errors && req.session_enabled?
        req.session["inertia_errors"] = errors
      end
      res.redirect_to(url, status: status)
    end

    private

    # Q4a-3 (flash/session API):
    #   req.flash => Hanami::Action::Flash.new(session["_flash"])
    #   flash["notice"] / flash["alert"] (string keys; Flash::KEY = "_flash")
    #   req.session["inertia_errors"] => env["rack.session"]["inertia_errors"] (string key)
    def build_inertia_props(req, config, user_props)
      shared  = config.shared_props.call(req)
      errors  = {}
      flash_p = {}

      if req.session_enabled?
        errors  = req.session["inertia_errors"] || {}
        flash   = req.flash
        flash_p[:notice] = flash["notice"] if flash.key?("notice")
        flash_p[:alert]  = flash["alert"]  if flash.key?("alert")
      end

      # inertia_rails controller.rb:127-152: shared merged first, then user props;
      # errors always present (always_include_errors_hash parity).
      result = {}
      result.merge!(shared)
      result.merge!(flash_p)
      result[:errors] = errors
      result.merge!(user_props)
      # Ensure errors key always present even if user_props overrode it
      result[:errors] = {} unless result.key?(:errors)
      result
    end

    # Path + query string for the page object url field.
    # Matches inertia_rails renderer.rb's request.original_fullpath.
    def build_url(req)
      qs = req.query_string
      qs.empty? ? req.path : "#{req.path}?#{qs}"
    end

    # inertia_rails middleware.rb:87
    def inertia_request?(req)
      req.env["HTTP_X_INERTIA"].to_s != ""
    end

    # inertia_rails renderer.rb:47-53 + Vary handling
    def apply_xhr_response(req, res, renderer)
      _status, _xhr_headers, body = renderer.render_xhr

      existing_vary = res.get_header("vary") || res.get_header("Vary")
      vary = existing_vary ? "#{existing_vary}, X-Inertia" : "X-Inertia"

      res.set_header("vary", vary)
      res.set_header("x-inertia", "true")
      res.set_header("content-type", "application/json")
      res.status = 200
      res.body   = body.join
    end

    # inertia_rails helper.rb:34-46 via render template: 'inertia'
    def apply_initial_response(res, renderer)
      _status, _headers, body = renderer.render_initial
      res.set_header("content-type", "text/html; charset=utf-8")
      res.status = 200
      res.body   = body.join
    end
  end
end
