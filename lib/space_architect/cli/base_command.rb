# frozen_string_literal: true

require "dry/cli"

module SpaceArchitect
  module CLI
    # Base for every space-architect command. dry-cli (>= 0.7.0) copies a
    # superclass's options to its subclasses, so the global colour options are
    # declared once here and inherited everywhere instead of being mixed in per
    # command. Helpers (terminal/store/render) ride along by inheritance too.
    class BaseCommand < Dry::CLI::Command
      include Helpers

      option :color,  type: :string, default: "auto", desc: "Color output: auto, always, never"
      option :colors, type: :string, desc: "Alias for --color"
    end
  end
end
