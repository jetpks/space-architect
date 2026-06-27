# frozen_string_literal: true

require "rack"

module HanamiForceSSL
  # Rack-3 middleware porting ActionDispatch::SSL + ActionDispatch::AssumeSSL.
  #
  # Options (mirror the ActionDispatch::SSL defaults):
  #   redirect:       true / false / Hash. Default {}. Hash keys:
  #                     exclude: ->(req){} — skip redirect + secure-cookie for matched requests
  #                     host:    override redirect host
  #                     port:    override redirect port
  #                     body:    override redirect body (default [])
  #                     status:  override redirect status (default 301/307 by method)
  #   hsts:           true / false / Hash. Default {}. Hash keys:
  #                     expires:    seconds (default 63072000 = 2yr)
  #                     subdomains: bool (default true → includeSubDomains)
  #                     preload:    bool (default false)
  #                   false → max-age=0 (instructs browsers to forget HSTS)
  #   secure_cookies: bool. Default true. Appends "; secure" to each Set-Cookie
  #                   on non-excluded SSL responses. Handles Rack-3 Array form.
  #   assume_ssl:     bool. Default false. When true, force-sets SSL env vars on
  #                   every request so ssl? is true behind a TLS-terminating proxy
  #                   that does not forward proto headers (ports AssumeSSL).
  #
  # Behavioral notes (matching the oracle):
  #   - HSTS is applied to every SSL response, including excluded-path responses.
  #   - Secure-cookie flagging is skipped on excluded paths.
  #   - redirect: false disables all redirects and secure-cookie flagging.
  #   - All response header names are lowercase (Rack-3 Lint requirement).
  class Middleware
    HSTS_EXPIRES_IN           = 63_072_000
    HSTS_DEFAULTS             = { expires: HSTS_EXPIRES_IN, subdomains: true, preload: false }.freeze
    PERMANENT_REDIRECT_METHODS = %w[GET HEAD].freeze

    def initialize(app, redirect: {}, hsts: {}, secure_cookies: true, assume_ssl: false)
      @app            = app
      @redirect       = redirect
      # Mirror oracle: with redirect: false, @exclude always returns true (never redirect).
      # With redirect: {}, @exclude is nil || proc{false} = proc{false} (redirect everything).
      # With redirect: { exclude: lambda }, @exclude = that lambda.
      @exclude        = @redirect && @redirect[:exclude] || proc { !@redirect }
      @secure_cookies = secure_cookies
      @assume_ssl     = assume_ssl
      @hsts_header    = build_hsts_header(normalize_hsts_options(hsts))
    end

    def call(env)
      if @assume_ssl
        env["HTTPS"]                  = "on"
        env["HTTP_X_FORWARDED_PORT"]  = "443"
        env["HTTP_X_FORWARDED_PROTO"] = "https"
        env["rack.url_scheme"]        = "https"
      end

      request = Rack::Request.new(env)

      if request.ssl?
        status, headers, body = @app.call(env)
        set_hsts_header!(headers)
        flag_cookies_as_secure!(headers) if @secure_cookies && !@exclude.call(request)
        [status, headers, body]
      else
        return redirect_to_https(request) unless @exclude.call(request)
        @app.call(env)
      end
    end

    private

    def set_hsts_header!(headers)
      headers["strict-transport-security"] ||= @hsts_header
    end

    def normalize_hsts_options(options)
      case options
      when false
        HSTS_DEFAULTS.merge(expires: 0)
      when nil, true
        HSTS_DEFAULTS.dup
      else
        HSTS_DEFAULTS.merge(options)
      end
    end

    def build_hsts_header(hsts)
      value = +"max-age=#{hsts[:expires].to_i}"
      value << "; includeSubDomains" if hsts[:subdomains]
      value << "; preload" if hsts[:preload]
      value
    end

    # Rack-3: Set-Cookie is an Array of strings (one per cookie).
    # Array() handles both String (legacy/direct assignment) and Array forms.
    def flag_cookies_as_secure!(headers)
      cookies = headers[Rack::SET_COOKIE]
      return unless cookies

      headers[Rack::SET_COOKIE] = Array(cookies).map do |cookie|
        if !/;\s*secure\s*(;|$)/i.match?(cookie)
          "#{cookie}; secure"
        else
          cookie
        end
      end
    end

    def redirect_to_https(request)
      [
        @redirect.fetch(:status, redirection_status(request)),
        {
          "content-type" => "text/html; charset=utf-8",
          "location"     => https_location_for(request)
        },
        (@redirect[:body] || [])
      ]
    end

    def redirection_status(request)
      PERMANENT_REDIRECT_METHODS.include?(request.request_method) ? 301 : 307
    end

    def https_location_for(request)
      host = @redirect[:host] || request.host
      port = @redirect[:port] || request.port

      location = +"https://#{host}"
      location << ":#{port}" if port != 80 && port != 443
      location << request.fullpath
      location
    end
  end
end
