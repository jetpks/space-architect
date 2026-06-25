# frozen_string_literal: true

require "space_src/cli"

module SpaceArchitect
  module CLI
    # Exit-code bridge to the migrated Space::Src (repo-tender) CLI engine.
    # `architect src <args>` hands the raw remainder to Space::Src's own dry-cli
    # registry and translates Space::Src's recorded Outcome into the host exit code.
    # Space::Src has its own Registry, Outcome, and :repo_tender_cli_* thread-locals;
    # this is the seam between the two registries (NOT a re-registration). Space::Src's
    # top-level help/version interceptors call Kernel.exit, so we reproduce that
    # interception here against the injected IO instead of delegating to them.
    # dry-cli's internal exit on a bare group / unknown command propagates as
    # SystemExit — same as the host's own bare groups (e.g. `space repo`) — and is
    # intentionally NOT rescued (accepted behavior change).
    def self.dispatch_src(rest, out = $stdout, err = $stderr)
      if ::Space::Src::CLI::TOP_LEVEL_HELP.include?(rest)
        out.puts Dry::CLI::Usage.call(::Space::Src::CLI::Registry.get([]))
        return 0
      end
      if ::Space::Src::CLI::VERSION_REQUEST.include?(rest)
        out.puts ::Space::Src::VERSION
        return 0
      end

      Thread.current[:repo_tender_cli_outcome] = nil
      Dry::CLI.new(::Space::Src::CLI::Registry).call(arguments: rest, out: out, err: err)
      ::Space::Src::CLI.last_outcome&.exit_code || 0
    end
  end
end
