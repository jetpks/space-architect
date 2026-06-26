# frozen_string_literal: true

module SpaceArchitect
  module CLI
    class Show < BaseCommand
      desc "Show metadata for a space or the current space"
      argument :identifier, required: false, desc: "Space ID or title slug"

      def call(identifier: nil, **opts)
        setup_terminal(**opts.slice(:color, :colors))
        render(store.find(identifier)) do |space|
          terminal.say "ID:         #{space.id}"
          terminal.say "Title:      #{space.title}"
          terminal.say "Status:     #{space.status}"
          terminal.say "Path:       #{terminal.path(space.path)}"
          terminal.say "Created:    #{space.data['created_at']}"
          terminal.say "Updated:    #{space.data['updated_at']}"
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end
      end
    end
  end
end

