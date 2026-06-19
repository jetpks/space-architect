# frozen_string_literal: true

module SpaceCadet
  module CLI
    class Path < Dry::CLI::Command
      include GlobalOptions
      include Helpers

      desc "Print the path for a space or the current space"
      argument :identifier, required: false, desc: "Space ID or title slug"

      def call(identifier: nil, **opts)
        setup_terminal(**opts.slice(:color, :colors))
        handle_errors do
          terminal.say terminal.path(store.path_for(identifier))
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

SpaceCadet::CLI::Registry.register "path", SpaceCadet::CLI::Path
