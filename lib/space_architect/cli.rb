# frozen_string_literal: true

require "dry/cli"

module Space::Architect
  module CLI
    Outcome = Data.define(:exit_code, :message) do
      def initialize(exit_code:, message: nil) = super
    end

    def self.record_outcome(o) = (Thread.current[:space_architect_outcome] = o)
    def self.last_outcome = Thread.current[:space_architect_outcome]

    module Registry
      extend Dry::CLI::Registry
    end

    TOP_LEVEL_HELP    = [[], ["--help"], ["-h"], ["help"]].freeze
    VERSION_REQUEST   = [["version"], ["--version"]].freeze

    def self.call(argv, out = $stdout, err = $stderr)
      Thread.current[:space_architect_outcome] = nil

      if TOP_LEVEL_HELP.include?(argv)
        out.puts Dry::CLI::Usage.call(Registry.get([]))
        return 0
      end

      if VERSION_REQUEST.include?(argv)
        out.puts Space::Core::VERSION
        return 0
      end

      if argv.first == "src"
        return dispatch_src(argv[1..], out, err)
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

    def self.run(argv, out = $stdout, err = $stderr)
      Kernel.exit(call(argv, out, err))
    rescue Interrupt
      err.puts "interrupted"
      Kernel.exit(130)
    end
  end
end

require_relative "cli/options"
require_relative "cli/helpers"
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
require_relative "cli/architect"
require_relative "cli/space"
require_relative "cli/src"
