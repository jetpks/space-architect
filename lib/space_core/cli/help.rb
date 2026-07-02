# frozen_string_literal: true

require "dry/cli"
require "pastel"

module Space::Core::CLI
  # Colourful replacement for dry-cli's plain `Usage` listing — the "global
  # help" shown by `space`, `architect`, and every bare namespace (`space repo`,
  # `worktree`, ...). Per-command help still flows through dry-cli's Banner,
  # whose content we like; only the listing is reskinned.
  #
  # We reopen Dry::CLI::Usage.call (below) to delegate here, so BOTH the
  # intercepted top-level help and dry-cli's own bare-namespace path get the
  # same treatment from one place. Colour follows CLI.help_pastel, set once per
  # invocation from the output stream's tty-ness and --color, so piped and test
  # output stay plain. The `src` binary never loads space_core, so its own plain
  # Usage is untouched.
  module Help
    # One tagline per binary — the root header is served for both `space` and
    # `architect` from here, so we pick by $PROGRAM_NAME. The default covers the
    # test runner and any other invocation where the binary can't be identified.
    TAGLINES = {
      "space"     => "date-prefixed workspaces; repos provisioned on fibers at copy-on-write speed",
      "architect" => "the Architect Loop: structured judgment plus a fleet of headless AI builders"
    }.freeze
    DEFAULT_TAGLINE = TAGLINES.fetch("space")

    module_function

    def call(result, pastel: CLI.help_pastel)
      rows  = listing(result)
      width = rows.map { |label, _| label.length }.max || 0

      lines = rows.map do |label, description|
        painted = pastel.cyan(label.ljust(width))
        description ? "  #{painted}   #{pastel.dim("# #{description}")}" : "  #{painted}"
      end

      [header(result, pastel), pastel.bold("Commands:"), *lines, footer(result, pastel)]
        .compact.join("\n")
    end

    # The richer header only makes sense at the true root (`space` / `architect`),
    # not on every sub-namespace listing.
    def header(result, pastel)
      return unless result.names.empty?

      "#{pastel.bold.cyan("space-architect")} #{pastel.dim(Space::Core::VERSION)} " \
        "#{pastel.dim("— #{tagline}")}\n"
    end

    # The tagline for the binary in hand: `space` and `architect` each get their
    # own, keyed off $PROGRAM_NAME (the same signal program_prefix reads).
    def tagline
      TAGLINES.fetch(File.basename($PROGRAM_NAME), DEFAULT_TAGLINE)
    end

    def footer(result, pastel)
      "\n#{pastel.dim("Run `#{program_prefix(result)} <command> --help` for details on a command.")}"
    end

    # "space" at the root, "space repo" inside a namespace. The `space`/`architect`
    # binaries inject their name into ARGV, so $PROGRAM_NAME and the leading
    # namespace segment can collide ("space space ..."); drop the duplicate.
    def program_prefix(result)
      prog  = File.basename($PROGRAM_NAME)
      names = result.names.dup
      names.shift if names.first == prog
      [prog, *names].join(" ")
    end

    # [[label_with_banner, description_or_nil], ...] sorted by command name.
    def listing(result)
      result.children.sort_by { |name, _| name }.filter_map do |name, node|
        next if node.hidden

        [label(result, name, node), description(node)]
      end
    end

    def label(result, name, node)
      "#{program_prefix(result)} #{name}#{banner(node)}"
    end

    def banner(node)
      if node.command && node.leaf? && node.children?
        " [ARGUMENT|SUBCOMMAND]"
      elsif node.leaf?
        arguments(node.command)
      else
        " [SUBCOMMAND]"
      end
    end

    def arguments(command)
      return "" unless command.respond_to?(:required_arguments)

      names = command.required_arguments.map { |arg| arg.name.to_s.upcase }
      names += command.optional_arguments.map { |arg| "[#{arg.name.to_s.upcase}]" }
      names.empty? ? "" : " #{names.join(" ")}"
    end

    def description(node)
      return unless node.leaf? && node.command.respond_to?(:description)

      node.command.description
    end
  end
end

# Route dry-cli's plain namespace/root listing through our colourful renderer.
# We prepend over Usage.call wholesale and depend only on the LookupResult/Node
# API (children, command, leaf?/children?/hidden, names) rather than copying
# Usage's internals — see notes/ruby-cli-gems-report.md.
module Dry
  class CLI
    module Usage
      module ColourPatch
        def call(result)
          Space::Core::CLI::Help.call(result)
        end
      end
      singleton_class.prepend(ColourPatch)
    end
  end
end
