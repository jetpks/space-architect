# frozen_string_literal: true

require "vite_ruby"

require_relative "vite_hanami/version"
require_relative "vite_hanami/tag_helpers"

module ViteHanami
  # Re-export for 4c to mount in the dev middleware chain (config.ru / Rack stack).
  # This is ViteRuby's DevServerProxy unchanged — F1b arbitration.
  DevServerProxy = ViteRuby::DevServerProxy
end
