# frozen_string_literal: true

module SpaceArchitect
  module CLI
    class Path < Dry::CLI::Command
      include GlobalOptions
      include Helpers

      desc "Print the path for a space or the current space"
      argument :identifier, required: false, desc: "Space ID or title slug"

      def call(identifier: nil, **opts)
        setup_terminal(**opts.slice(:color, :colors))
        render(store.path_for(identifier)) do |path|
          terminal.say terminal.path(path)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

SpaceArchitect::CLI::Registry.register "path", SpaceArchitect::CLI::Path
