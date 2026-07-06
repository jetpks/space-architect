# frozen_string_literal: true

require "dry/cli"
require "pastel"
require_relative "loop_status"

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

    # Header for the trailing group of children that declare no phase. Left nil
    # for the `space` binary (whose commands are all phase-less → one ungrouped
    # listing); the `architect` binary sets it so its namespaces list under a
    # "Groups" header. Keeps phase vocabulary out of this generic renderer.
    def self.trailing_group_label = @trailing_group_label

    def self.trailing_group_label=(label)
      @trailing_group_label = label
    end

    def call(result, pastel: CLI.help_pastel)
      groups = grouped_listing(result)
      width  = groups.flat_map { |_h, rows| rows.map { |label, _| label.length } }.max || 0

      body = groups.flat_map do |group_header, rows|
        lines = rows.map do |label, description|
          painted = pastel.cyan(label.ljust(width))
          description ? "  #{painted}   #{pastel.dim("# #{description}")}" : "  #{painted}"
        end
        group_header ? ["", pastel.bold(group_header), *lines] : lines
      end

      [header(result, pastel), pastel.bold("Commands:"), *body,
       footer(result, pastel), loop_status_block(result, pastel)].compact.join("\n")
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

    # Group non-hidden children into an ordered list of [header_or_nil, rows].
    # When no child declares a phase (e.g. the `space` binary), returns a single
    # unlabelled group sorted by name — byte-identical to the pre-phase listing.
    # Otherwise groups declared commands under their phase label (groups, and
    # members within a group, ordered by the declared order), with undeclared
    # children (namespaces) trailing in the default group.
    def grouped_listing(result)
      decorated = result.children.filter_map do |name, node|
        [name, node, phase_of(node)] unless node.hidden
      end

      if decorated.all? { |_name, _node, phase| phase.nil? }
        rows = decorated.sort_by { |name, _node, _phase| name }
                        .map { |name, node, _phase| row(result, name, node) }
        return [[nil, rows]]
      end

      phased, unphased = decorated.partition { |_name, _node, phase| phase }
      groups = phased.group_by { |_name, _node, phase| phase.last }
      listing = groups.sort_by { |_label, members| members.map { |_n, _node, phase| phase.first }.min }
                      .map do |label, members|
        rows = members.sort_by { |_n, _node, phase| phase.first }
                      .map { |name, node, _phase| row(result, name, node) }
        [label, rows]
      end
      listing << [trailing_group_label, unphased.map { |name, node, _phase| row(result, name, node) }] \
        unless unphased.empty?
      listing
    end

    def row(result, name, node)
      [label(result, name, node), description(node)]
    end

    def phase_of(node)
      node.command.respond_to?(:phase) ? node.command.phase : nil
    end

    # Opportunistic, TOTAL loop-status embed: only the architect binary's ROOT
    # listing gets it. Resolves the current space best-effort and renders the
    # shared block from that space's own space.yaml `project` data (no
    # space_architect dependency). ANY failure — no space, store failure,
    # malformed yaml, no `project` block — omits the block; help always renders.
    def loop_status_block(result, pastel)
      return unless result.names.empty? && File.basename($PROGRAM_NAME) == "architect"

      project = current_space_project
      lines = project && LoopStatus.lines(project)
      return if lines.nil? || lines.empty?

      ["", pastel.bold("Loop:"), *lines.map { |l| "  #{pastel.dim(l)}" }].join("\n")
    rescue StandardError
      nil
    end

    def current_space_project
      store = Space::Core::SpaceStore.new(config: Space::Core::Config.load, state: Space::Core::State.load)
      store.current.value_or(nil)&.data&.[]("project")
    rescue StandardError
      nil
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
