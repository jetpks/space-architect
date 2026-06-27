# frozen_string_literal: true

module Space::Core::CLI
class List < Dry::CLI::Command
  include GlobalOptions
  include Helpers

  desc "List spaces"

  def call(**opts)
    setup_terminal(**opts.slice(:color, :colors))
    handle_errors do
      spaces = store.list
      if spaces.empty?
        terminal.say "No spaces found in #{terminal.path(project_config.spaces_dir)}"
        next
      end

      rows = spaces.map do |space|
        [space.status, display_date(space), space.title, terminal.path(space.path)]
      end
      terminal.say terminal.table(%w[Status Date Title Path], rows)
      CLI.record_outcome(Outcome.new(exit_code: 0))
    end
  end
end
end
