# frozen_string_literal: true

require "minitest/autorun"
require "vite_hanami"

FIXTURE_ROOT = File.expand_path("fixtures", __dir__)

# Returns a ViteRuby instance pointed at the fixture config/vite.json.
# mode: "production" → build mode (dev_server_running? = false, reads manifest fixture)
# mode: "development" → use with dev_instance() to get dev-server-on instance
def build_vite(mode: "production")
  ViteRuby.new(root: FIXTURE_ROOT, mode: mode)
end

# Returns a development-mode ViteRuby instance with dev_server_running? = true.
# Uses define_singleton_method to avoid a TCP connection attempt.
def dev_instance
  vite = build_vite(mode: "development")
  vite.define_singleton_method(:dev_server_running?) { true }
  vite
end
