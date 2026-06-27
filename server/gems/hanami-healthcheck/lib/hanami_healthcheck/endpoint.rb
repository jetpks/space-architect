# frozen_string_literal: true

module HanamiHealthcheck
  class Endpoint
    HTML_UP   = '<html><body style="background:#4ade80"><h1>up</h1></body></html>'
    HTML_DOWN = '<html><body style="background:#f87171"><h1>down</h1></body></html>'
    JSON_UP   = '{"status":"up"}'
    JSON_DOWN = '{"status":"down"}'

    def initialize(checks: [])
      @checks = Array(checks)
    end

    def call(env)
      up = healthy?
      status = up ? 200 : 503
      json = (env["HTTP_ACCEPT"] || "").include?("application/json")

      if json
        [status, {"content-type" => "application/json"}, [up ? JSON_UP : JSON_DOWN]]
      else
        [status, {"content-type" => "text/html"}, [up ? HTML_UP : HTML_DOWN]]
      end
    end

    private

    def healthy?
      return true if @checks.empty?

      @checks.all? do |check|
        begin
          check.call
        rescue
          false
        end
      end
    end
  end
end
