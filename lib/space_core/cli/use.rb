# frozen_string_literal: true

module Space::Core::CLI
class Use < BaseCommand
  desc "Remember a space in recent state and print its path"
  argument :identifier, required: true, desc: "Space ID or title slug"

  def call(identifier:, **opts)
    setup_terminal(**opts.slice(:color, :colors))
    render(store.use(identifier)) do |space|
      terminal.success "Recent space: #{space.id}"
      terminal.say terminal.path(space.path)
      CLI.record_outcome(Outcome.new(exit_code: 0))
    end
  end
end
end
