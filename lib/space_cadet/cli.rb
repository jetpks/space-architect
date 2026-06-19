# frozen_string_literal: true

require "dry/cli"

module SpaceCadet
  module CLI
    Outcome = Data.define(:exit_code, :message) do
      def initialize(exit_code:, message: nil) = super
    end

    def self.record_outcome(o) = (Thread.current[:space_cadet_outcome] = o)
    def self.last_outcome = Thread.current[:space_cadet_outcome]

    module Registry
      extend Dry::CLI::Registry
    end

    def self.call(argv, out = $stdout, err = $stderr)
      Thread.current[:space_cadet_outcome] = nil
      Dry::CLI.new(Registry).call(arguments: normalize_args(argv), out: out, err: err)
      last_outcome&.exit_code || 0
    end

    # Move leading --color/--colors options to after the command token so
    # dry-cli's command routing isn't confused by options before the subcommand.
    def self.normalize_args(argv)
      args = argv.dup
      extracted = []
      index = 0

      while index < args.length
        arg = args[index]
        break if arg == "--"

        if %w[--color --colors].include?(arg)
          extracted << args.delete_at(index)
          if args[index] && !args[index].start_with?("-")
            extracted << args.delete_at(index)
          end
        elsif arg.start_with?("--color=", "--colors=")
          extracted << args.delete_at(index)
        else
          index += 1
        end
      end

      return args if extracted.empty?

      cmd_index = args.index { |a| !a.start_with?("-") }
      return args + extracted unless cmd_index

      args.insert(cmd_index + 1, *extracted)
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
