# frozen_string_literal: true

require "vite_ruby"

Hanami.app.register_provider(:vite) do
  start do
    # Resolve root from __dir__ so it's invariant to Dir.pwd (test vs dev).
    # __dir__ = architect/config/providers → ../.. = architect/
    root = Pathname(__dir__).join("../..").realpath
    ViteRuby.reload_with(root: root)
    register("vite", ViteRuby.instance)
  end
end
