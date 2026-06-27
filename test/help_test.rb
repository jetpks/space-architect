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
  def core_config_ns = Space::Core::CLI::Registry.get(["config"])

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
