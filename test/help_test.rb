# frozen_string_literal: true

require_relative "test_helper"
require "pastel"

# Covers the colourful help listing (lib/space_core/cli/help.rb) and the
# Dry::CLI::Usage reopen that routes every namespace listing through it. The
# split keeps three registries; the help machinery lives in Space::Core::CLI and
# serves the `space` and `architect` binaries (the `src` binary never loads
# space_core, so its plain Usage is untouched).
class HelpTest < Space::ArchitectTest
  def architect_root = Space::Architect::CLI::Registry.get([])
  def space_root = Space::Core::CLI::Registry.get([])
  def core_config_ns = Space::Core::CLI::Registry.get(["config"])

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
  def test_space_help_stays_ungrouped_and_alpha_sorted
    with_program_name("space") do
      plain = Space::Core::CLI::Help.call(space_root, pastel: Pastel.new(enabled: false))

      PHASE_HEADERS.each { |h| refute_match(/^#{h}$/, plain, "no phase header in `space` help") }
      assert_operator plain.index("space build"), :<, plain.index("space config")
      assert_operator plain.index("space status"), :<, plain.index("space use")
      assert_match(/space status \[REST\]\s+# Set a space status/, plain)
    end
  end

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

    assert_match("space-architect", plain)
    assert_match(/Run `.*--help`/, plain)
  end

  def test_namespace_does_not_double_the_program_name
    with_program_name("space") do
      plain = Space::Core::CLI::Help.call(core_config_ns, pastel: Pastel.new(enabled: false))

      refute_match(/space space/, plain)
      assert_match(/space config show/, plain)
    end
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
