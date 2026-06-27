# frozen_string_literal: true

require "dry/cli"

module Space::Core::CLI
  # Base for every space/architect command. dry-cli (>= 0.7.0) copies a
  # superclass's options to its subclasses, so the global colour options are
  # declared once here and inherited everywhere instead of being mixed in per
  # command. Helpers (terminal/store/render) ride along by inheritance too.
  #
  # The `src` binary has its own output-mode system (--plain/--json) and does
  # NOT inherit from this base.
  class BaseCommand < Dry::CLI::Command
    include Helpers

    option :color,  type: :string, default: "auto", desc: "Color output: auto, always, never"
    option :colors, type: :string, desc: "Alias for --color"
  end
end
