# frozen_string_literal: true

module SpaceCadet
  module CLI
    class Current < Dry::CLI::Command
      include GlobalOptions
      include Helpers

      desc "Show the current space"

      def call(**opts)
        setup_terminal(**opts.slice(:color, :colors))
        handle_errors do
          space = store.find
          terminal.say space.id.to_s
          terminal.say terminal.path(space.path)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

SpaceCadet::CLI::Registry.register "current", SpaceCadet::CLI::Current
