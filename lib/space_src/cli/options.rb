# frozen_string_literal: true

module Space::Src
  module CLI
    # Shared output mode flags. Include in any command class to add:
    #   --plain     force plain text output (one line per event, ANSI-free)
    #   --json      force JSON output (one object per event line, 12-factor)
    #   --no-color  disable ANSI color
    #   --quiet/-q  suppress non-essential human output
    #
    # Resolved via UI::Mode.resolve in the command's #call.
    module GlobalOptions
      def self.included(base)
        base.option :plain, type: :flag, desc: "Plain text output (one line per event, no color)"
        base.option :json, type: :flag, desc: "JSON output (one object per event line, 12-factor)"
        base.option :no_color, type: :flag, desc: "Disable color output"
        base.option :quiet, type: :flag, aliases: ["-q"], desc: "Suppress non-essential output"
      end
    end
  end
end
