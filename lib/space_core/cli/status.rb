# frozen_string_literal: true

module Space::Core::CLI
class Status < BaseCommand
  desc "Set a space status: active, paused, done, archived"
  argument :rest, type: :array, required: false, desc: "[SPACE] STATUS"

  # One command, overloaded by its positional(s):
  #   help token (`help`, or dry-cli's -h/--help which never reach here) → help
  #   lone keyword / `<space> <keyword>`                                 → set
  #   bare, or a lone non-keyword identifier                            → report
  def call(rest: [], **opts)
    setup_terminal(**opts.slice(:color, :colors))
    args = Array(rest)
    return show_help if help_token?(args)

    handle_errors do
      if set_args?(args)
        set_status(args)
      elsif args.length <= 1
        report(args.first)
      else
        raise Space::Core::Error, "Usage: space status [SPACE] STATUS"
      end
    end
  end

  private

  # The bare word `help` shows the command help, like dry-cli's -h/--help (which
  # it intercepts before dispatch). It must never set status to "help" or report.
  def help_token?(args)
    args == ["help"]
  end

  def show_help
    out.puts Dry::CLI::Banner.call(self.class, Dry::CLI::ProgramName.call(["status"]))
    CLI.record_outcome(Outcome.new(exit_code: 0))
  end

  # A set request: `<space> <keyword>` (two args), or a lone status keyword. A
  # lone non-keyword arg is a space identifier to REPORT, not a malformed status.
  def set_args?(args)
    args.length == 2 ||
      (args.length == 1 && Space::Core::Space::VALID_STATUSES.include?(args.first))
  end

  def set_status(args)
    identifier, status_value = args.length == 2 ? args : [nil, args.first]
    render(store.find(identifier)) do |space|
      space.update_status(status_value)
      terminal.success "#{space.id} is #{space.status}"
      CLI.record_outcome(Outcome.new(exit_code: 0))
    end
  end

  def report(identifier)
    render(store.find(identifier)) do |space|
      terminal.say "ID:         #{space.id}"
      terminal.say "Title:      #{space.title}"
      terminal.say "Status:     #{space.status}"
      terminal.say "Path:       #{terminal.path(space.path)}"
      terminal.say "Created:    #{space.data['created_at']}"
      terminal.say "Updated:    #{space.data['updated_at']}"
      lines = LoopStatus.lines(space.data["project"])
      if lines
        terminal.say ""
        lines.each { |line| terminal.say line }
      end
      CLI.record_outcome(Outcome.new(exit_code: 0))
    end
  end
end
end
