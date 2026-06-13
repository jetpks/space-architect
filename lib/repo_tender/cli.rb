# frozen_string_literal: true

require "dry/cli"
require "repo_tender"

module RepoTender
  # CLI surface — thin translation layer between argv and the
  # existing Config::Store / State::Store / Sync::Engine boundaries.
  #
  # The CLI never mutates a git repo directly; repo mutation happens
  # inside the engine, which already upholds the no-data-loss
  # invariant (PRD §1). The CLI's job is:
  #   1. parse argv (via Dry::CLI's nested `register`)
  #   2. load/mutate validated config (Config::Store) OR delegate to
  #      the engine / state store
  #   3. translate Result to: out/err message + exit code
  #
  # Exit-code seam: each command records an `Outcome(exit_code:,
  # message:)` (the thread-local stash) and writes the user-facing
  # message to `out`/`err` via the injected IOs. The `bin/repo-tender`
  # entrypoint reads the recorded Outcome and calls Kernel.exit with
  # the code — see CLI.run below. Tests can inspect last_outcome
  # in-process (no subprocess needed for unit tests); a subprocess
  # Open3.capture3 covers the G3 "real exit" proof.
  module CLI
    # The Outcome value object. `exit_code` is 0 for success and 1
    # for Failure-derived failures. `message` is the user-facing
    # explanation already written to err (kept here so the
    # entrypoint could log/record it in a future slice).
    Outcome = Data.define(:exit_code, :message) do
      def initialize(exit_code:, message: nil)
        super
      end
    end

    # Thread-local env hash. Defaults to ENV. Tests inject a temp
    # HOME / XDG_* hash via Thread.current[:repo_tender_cli_env] =
    # env_hash. The CLI's `make_paths` reads this to resolve the
    # config/state file locations under the test's temp home.
    def self.env
      Thread.current[:repo_tender_cli_env] || ENV
    end

    # Thread-local Outcome stash. The most recent command's Outcome
    # is read by CLI.run to set the process exit code.
    def self.record_outcome(outcome)
      Thread.current[:repo_tender_cli_outcome] = outcome
    end

    def self.last_outcome
      Thread.current[:repo_tender_cli_outcome]
    end

    # Program-name-level invocations that must succeed (exit 0) with
    # output on stdout. Dry::CLI has no root command registered, so it
    # would otherwise route these through its "command not found" path
    # (Usage → stderr → exit 1). We intercept ONLY the exact top-level
    # forms here; a *leaf* help like `sync --help` (argv ["sync",
    # "--help"]) and a *group* like `repo` / `repo --help` are NOT
    # matched, so Dry::CLI keeps handling them as before (leaf help →
    # stdout/exit 0; group → usage/stderr/exit 1, accepted per G7).
    TOP_LEVEL_HELP = [[], ["--help"], ["-h"], ["help"]].freeze
    VERSION_REQUEST = [["version"], ["--version"]].freeze

    # Entrypoint. Called by bin/repo-tender. Intercepts the top-level
    # help/version forms (stdout, exit 0), otherwise hands argv to
    # Dry::CLI for command dispatch and translates the last Outcome to
    # a process exit code.
    def self.run(argv, stdout, stderr)
      return print_usage(stdout) if TOP_LEVEL_HELP.include?(argv)
      return print_version(stdout) if VERSION_REQUEST.include?(argv)

      Dry::CLI.new(Registry).call(arguments: argv, out: stdout, err: stderr)
      outcome = last_outcome
      Kernel.exit(outcome&.exit_code || 0)
    end

    # Render the top-level command-group listing (reusing Dry::CLI's
    # own Usage formatter so it stays in sync with the registry) to
    # stdout and exit 0.
    def self.print_usage(stdout)
      stdout.puts Dry::CLI::Usage.call(Registry.get([]))
      Kernel.exit(0)
    end

    # Print the gem version to stdout and exit 0.
    def self.print_version(stdout)
      stdout.puts RepoTender::VERSION
      Kernel.exit(0)
    end

    # Internal: build a Paths instance scoped to the active env
    # (Thread.current[:repo_tender_cli_env] || ENV). Every command
    # uses this so tests can inject a temp home without mutating
    # the real ENV.
    def self.make_paths
      Paths.new(environment: env)
    end

    # The Dry::CLI::Registry-extended module. The subcommand files
    # (cli/repo.rb, cli/org.rb, …) call `register "x" do |p| ... end`
    # on this module at load time.
    module Registry
      extend Dry::CLI::Registry
    end
  end
end

# Subcommand files — each defines its command classes and
# registers them under their group prefix.
require "repo_tender/cli/repo"
require "repo_tender/cli/org"
require "repo_tender/cli/sync"
require "repo_tender/cli/status"
require "repo_tender/cli/config"
require "repo_tender/cli/daemon"
