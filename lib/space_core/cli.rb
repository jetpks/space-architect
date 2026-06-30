# frozen_string_literal: true

require "dry/cli"
require "pastel"
require_relative "cli/repeatable_options"
require_relative "cli/help"

module Space::Core
  module CLI
    CLI = self

    Outcome = Data.define(:exit_code, :message) do
      def initialize(exit_code:, message: nil) = super
    end

    def self.record_outcome(o) = (Thread.current[:space_core_cli_outcome] = o)
    def self.last_outcome = Thread.current[:space_core_cli_outcome]

    # Pastel used by the colourful help listing (Help / the Usage reopen). Set
    # per-invocation in .call from the output stream and --color; defaults to a
    # disabled instance so non-CLI callers and tests render plain text.
    def self.help_pastel = @help_pastel ||= Pastel.new(enabled: false)

    def self.help_pastel=(pastel)
      @help_pastel = pastel
    end

    # Whether the help listing should be colourised: honour an explicit
    # --color/--colors (always/never), otherwise auto-detect from the streams the
    # listing can land on (stdout for top-level help, stderr for bare namespaces).
    def self.help_colors?(argv, out, err)
      case color_mode(argv)
      when "always" then true
      when "never"  then false
      else tty?(out) || tty?(err)
      end
    end

    def self.tty?(io) = io.respond_to?(:tty?) && io.tty?

    def self.color_mode(argv)
      argv.each_with_index do |arg, i|
        return arg.split("=", 2)[1].to_s.downcase if arg.start_with?("--color=", "--colors=")
        return argv[i + 1].to_s.downcase if %w[--color --colors].include?(arg)
      end
      "auto"
    end

    module Registry
      extend Dry::CLI::Registry
    end

    TOP_LEVEL_HELP  = [[], ["--help"], ["-h"], ["help"]].freeze
    VERSION_REQUEST = [["version"], ["--version"]].freeze

    def self.call(argv, out = $stdout, err = $stderr)
      Thread.current[:space_core_cli_outcome] = nil
      self.help_pastel = Pastel.new(enabled: help_colors?(argv, out, err))

      if TOP_LEVEL_HELP.include?(argv)
        print_usage(out)
        return 0
      end

      if VERSION_REQUEST.include?(argv)
        print_version(out)
        return 0
      end

      Dry::CLI.new(Registry).call(arguments: normalize_args(argv), out: out, err: err)
      last_outcome&.exit_code || 0
    end

    # Move --color/--colors options to the end of the argument list so dry-cli's
    # command routing is not confused by options before the subcommand name.
    #
    # Two passes:
    #   1. Leading: extract two-token form (--color VALUE) and =-form from the
    #      front while args still look like options.
    #   2. Non-leading: extract =-form (--color=VALUE / --colors=VALUE) from any
    #      position before the -- separator. The bare two-token form is ambiguous
    #      with a subcommand name in non-leading position and is left in place.
    def self.normalize_args(argv)
      args = argv.dup
      extracted = []

      # Pass 1: leading two-token and =-form (existing behavior, unchanged)
      while (arg = args.first) && arg != "--" && arg.start_with?("-")
        if %w[--color --colors].include?(arg)
          extracted << args.shift
          extracted << args.shift if args.first && !args.first.start_with?("-")
        elsif arg.start_with?("--color=", "--colors=")
          extracted << args.shift
        else
          break
        end
      end

      # Pass 2: =-form from any non-leading position, stop at --
      sep = args.index("--")
      head = sep ? args[0, sep] : args
      tail = sep ? args[sep..] : []
      mid_color, head = head.partition { |a| a.start_with?("--color=", "--colors=") }
      extracted += mid_color
      args = head + tail

      extracted.empty? ? args : args + extracted
    end

    def self.print_usage(out)
      out.puts Dry::CLI::Usage.call(Registry.get([]))
    end

    def self.print_version(out)
      out.puts ::Space::Core::VERSION
    end

    def self.run(argv, out = $stdout, err = $stderr)
      Kernel.exit(call(argv, out, err))
    rescue Interrupt
      err.puts "interrupted"
      Kernel.exit(130)
    end
  end
end

require_relative "cli/helpers"
require_relative "cli/base_command"
require_relative "cli/init"
require_relative "cli/new"
require_relative "cli/list"
require_relative "cli/show"
require_relative "cli/path"
require_relative "cli/use"
require_relative "cli/current"
require_relative "cli/status"
require_relative "cli/config"
require_relative "cli/repo"
require_relative "cli/shell"
require_relative "cli/pack"
require_relative "cli/run"

Space::Core::CLI::Registry.register "init",    Space::Core::CLI::Init
Space::Core::CLI::Registry.register "new",     Space::Core::CLI::New
Space::Core::CLI::Registry.register "list",    Space::Core::CLI::List
Space::Core::CLI::Registry.register "ls",      Space::Core::CLI::List
Space::Core::CLI::Registry.register "show",    Space::Core::CLI::Show
Space::Core::CLI::Registry.register "path",    Space::Core::CLI::Path
Space::Core::CLI::Registry.register "use",     Space::Core::CLI::Use
Space::Core::CLI::Registry.register "current", Space::Core::CLI::Current
Space::Core::CLI::Registry.register "status",  Space::Core::CLI::Status
Space::Core::CLI::Registry.register "config" do |c|
  c.register "show", Space::Core::CLI::Config::Show
  c.register "path", Space::Core::CLI::Config::ConfigPath
  c.register "set",  Space::Core::CLI::Config::Set
end
Space::Core::CLI::Registry.register "repo" do |r|
  r.register "add",     Space::Core::CLI::Repo::Add
  r.register "list",    Space::Core::CLI::Repo::RepoList
  r.register "ls",      Space::Core::CLI::Repo::RepoList
  r.register "resolve", Space::Core::CLI::Repo::Resolve
end
Space::Core::CLI::Registry.register "repos" do |r|
  r.register "add",     Space::Core::CLI::Repo::Add
  r.register "list",    Space::Core::CLI::Repo::RepoList
  r.register "ls",      Space::Core::CLI::Repo::RepoList
  r.register "resolve", Space::Core::CLI::Repo::Resolve
end
Space::Core::CLI::Registry.register "shell" do |s|
  s.register "init",     Space::Core::CLI::Shell::ShellInit
  s.register "fish",     Space::Core::CLI::Shell::Fish
  s.register "complete", Space::Core::CLI::Shell::Complete
end
Space::Core::CLI::Registry.register "pack", Space::Core::CLI::Pack
Space::Core::CLI::Registry.register "run",  Space::Core::CLI::Run
