# frozen_string_literal: true

require_relative "cli/test_helper"
require "space_src/shell_integration"
require "space_src/cli"

class SrcShellIntegrationTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  ShellIntegration = Space::Src::ShellIntegration
  CLI = Space::Src::CLI

  def fish_script
    @fish_script ||= ShellIntegration.for("fish")
  end

  # ---- module standalone — no SpaceArchitect reference ----

  def test_module_has_no_space_architect_reference
    src = File.read(File.expand_path("../../lib/space_src/shell_integration.rb", __dir__))
    refute_match(/space_?architect/i, src,
      "shell_integration.rb must not reference SpaceArchitect")
  end

  def test_fish_script_has_no_space_architect_reference
    refute_match(/space_?architect/i, fish_script,
      "generated fish script must not reference SpaceArchitect")
  end

  # ---- script defines function src ----

  def test_fish_script_defines_function_src
    assert_includes fish_script, "function src",
      "fish script must define function src"
  end

  # ---- cd logic: captures and prints output ----

  def test_fish_script_captures_command_output
    assert_match(/set.*__src_output.*command src/, fish_script,
      "fish script must capture src output into a variable")
  end

  def test_fish_script_prints_captured_output
    assert_match(/printf.*__src_output/, fish_script,
      "fish script must print captured output")
  end

  # ---- cd logic: IFF exit status 0, take last line ----

  def test_fish_script_checks_exit_status_0
    assert_match(/if test.*__src_status.*-eq 0/, fish_script,
      "fish script must gate cd on exit status 0")
  end

  def test_fish_script_takes_last_output_line
    assert_match(/__src_output\[-1\]/, fish_script,
      "fish script must take the last output line")
  end

  # ---- cd logic: tilde expansion ----

  def test_fish_script_tilde_expands
    assert_match(/string replace.*\^~/, fish_script,
      "fish script must tilde-expand the target path")
  end

  # ---- cd logic: guards on test -d ----

  def test_fish_script_guards_on_directory
    assert_match(/if test -d/, fish_script,
      "fish script must guard on the path being a directory before cd")
  end

  # ---- cd logic: cds into the target ----

  def test_fish_script_cds_into_target
    assert_includes fish_script, "cd \"$__src_target\"",
      "fish script must cd into the resolved path"
  end

  # ---- known subcommands do NOT cd ----

  def test_fish_script_passes_through_known_subcommands_without_cd
    # The known subcommands are in a 'case' branch that calls `command src`
    # directly without any cd logic.
    assert_match(/case repo org sync status config daemon clone shell/, fish_script,
      "fish script must list known subcommands in a pass-through case")
  end

  def test_fish_script_known_subcommands_branch_has_no_cd
    # Extract the pass-through branch lines (between "case repo..." and "case '*'")
    lines = fish_script.lines
    passthrough_start = lines.index { |l| l.include?("case repo org") }
    wildcard_start = lines.index { |l| l.strip == "case '*'" }
    assert passthrough_start, "must have a pass-through case"
    assert wildcard_start, "must have a wildcard case"
    passthrough_lines = lines[passthrough_start...wildcard_start].join
    refute_includes passthrough_lines, "cd \"$__src_target\"",
      "pass-through branch must not contain a cd call"
  end

  # ---- src shell init fish command ----

  def test_src_shell_init_fish_prints_fish_script
    with_cli_env do
      out, _err = invoke_command(CLI::Shell::Init, shell_name: "fish")
      assert_equal 0, CLI.last_outcome.exit_code
      assert_includes out.string, "function src"
    end
  end

  def test_src_shell_init_unknown_shell_exits_1
    with_cli_env do
      _out, err = invoke_command(CLI::Shell::Init, shell_name: "zsh")
      assert_equal 1, CLI.last_outcome.exit_code
      assert_includes err.string, "zsh"
    end
  end

  # ---- shell is registered as a top-level group ----

  def test_shell_is_registered_in_registry
    assert CLI::Registry.get([]).children.key?("shell"),
      "shell must be a registered top-level group"
  end
end
