# frozen_string_literal: true

require_relative "test_helper"
require "pastel"

# Covers the colourful help listing (Space::Core::CLI::Help, from the
# space-cadet gem) and the Dry::CLI::Usage reopen that routes every namespace
# listing through it. The help machinery lives in Space::Core::CLI and serves
# the architect binary's registry.
class HelpTest < Space::ArchitectTest
  def architect_root = Space::Architect::CLI::Registry.get([])

  PHASE_HEADERS = %w[Spec Build Judge Land Project Groups].freeze

  # AC1: the architect listing is grouped under loop-phase headers in canonical
  # order, commands ordered by loop step within each group, each exactly once.
  def test_architect_help_groups_commands_by_loop_phase
    plain = with_program_name("architect") do
      Space::Core::CLI::Help.call(architect_root, pastel: Pastel.new(enabled: false))
    end

    positions = PHASE_HEADERS.map { |h| plain.index(/^#{h}$/) }
    assert positions.all?, "every phase header must be present: #{PHASE_HEADERS.zip(positions).inspect}"
    assert_equal positions, positions.sort, "phase headers must appear in canonical order"

    # loop order within a group (not alpha): Spec is new → section → freeze
    assert_operator plain.index("architect new "), :<, plain.index("architect section ")
    assert_operator plain.index("architect section "), :<, plain.index("architect freeze ")
    # namespaces land under the trailing Groups header
    assert_operator plain.index(/^Groups$/), :<, plain.index("architect worktree ")

    %w[init ground new status freeze verify provision dispatch section verdict
       evidence merge integrate gate install-skills bug-report brief worktree
       variant research].each do |cmd|
      count = plain.scan(/^  architect #{Regexp.escape(cmd)}(?=[ \[\n])/).length
      assert_equal 1, count, "#{cmd} must appear exactly once, saw #{count}"
    end
  end

  # AC1: the `space` listing declares no phase → single default listing, no phase
  # headers, alpha-sorted — byte-unchanged from before.
  def test_plain_listing_has_no_ansi_but_keeps_dry_cli_tokens
    plain = Space::Core::CLI::Help.call(architect_root, pastel: Pastel.new(enabled: false))

    refute_match(/\e\[/, plain, "plain listing must not contain ANSI escapes")
    assert_match("Commands:", plain)
    assert_match(/worktree \[SUBCOMMAND\]/, plain)
    assert_match(/variant \[SUBCOMMAND\]/, plain)
  end

  def test_colored_listing_emits_ansi_escapes
    colored = Space::Core::CLI::Help.call(architect_root, pastel: Pastel.new(enabled: true))

    assert_match(/\e\[/, colored, "colored listing must contain ANSI escapes")
  end

  def test_root_listing_carries_a_header_and_footer
    plain = Space::Core::CLI::Help.call(architect_root, pastel: Pastel.new(enabled: false))

    # The header brands the host binary (product_name/version set at require
    # time in cli/architect.rb — space-cadet >= 9.1's seam); the per-binary
    # tagline keys off $PROGRAM_NAME, which the real `architect` binary
    # supplies. The footer routes to per-command help.
    assert_match(/\Aarchitect #{Space::Architect::VERSION} — /, plain)
    assert_match(/Run `.*--help`/, plain)
  end

  def test_usage_reopen_delegates_to_help
    assert_equal Space::Core::CLI::Help.call(architect_root, pastel: Pastel.new(enabled: false)),
                 with_program_name($PROGRAM_NAME) { plain_usage(architect_root) }
  end

  private

  def plain_usage(result)
    Space::Core::CLI.help_pastel = Pastel.new(enabled: false)
    Dry::CLI::Usage.call(result)
  end

  def with_program_name(name)
    original = $PROGRAM_NAME
    $PROGRAM_NAME = name
    yield
  ensure
    $PROGRAM_NAME = original
  end
end
