# frozen_string_literal: true

require "space_core/cli"

module Space::Architect
  module CLI
    # Exit-code bridge to the Space::Core CLI engine.
    # `architect space <args>` (and `exe/space <args>` via Space::Core::CLI directly)
    # hands the raw remainder to Space::Core's own dry-cli registry and translates
    # Space::Core's recorded Outcome into the host exit code.
    # Space::Core has its own Registry, Outcome, and :space_core_cli_outcome thread-local;
    # this is the seam between the two registries (NOT a re-registration).
    def self.dispatch_space(rest, out = $stdout, err = $stderr)
      if ::Space::Core::CLI::TOP_LEVEL_HELP.include?(rest)
        out.puts Dry::CLI::Usage.call(::Space::Core::CLI::Registry.get([]))
        return 0
      end

      if ::Space::Core::CLI::VERSION_REQUEST.include?(rest)
        out.puts ::Space::Core::VERSION
        return 0
      end

      Thread.current[:space_core_cli_outcome] = nil
      Dry::CLI.new(::Space::Core::CLI::Registry).call(arguments: rest, out: out, err: err)
      ::Space::Core::CLI.last_outcome&.exit_code || 0
    end
  end
end
