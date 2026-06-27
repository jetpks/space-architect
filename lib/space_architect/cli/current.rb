# frozen_string_literal: true

module Space::Architect
  module CLI
    class Current < Dry::CLI::Command
      include GlobalOptions
      include Helpers

      desc "Show the current space"

      def call(**opts)
        setup_terminal(**opts.slice(:color, :colors))
        render(store.find) do |space|
          terminal.say space.id.to_s
          terminal.say terminal.path(space.path)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

