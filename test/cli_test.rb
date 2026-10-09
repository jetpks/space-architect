# frozen_string_literal: true

require_relative "test_helper"

# Loop-subject CLI tests. The space-tool tests that used to live here tested
# the `architect space …` forwarder; the forwarder is gone (9.0.0 split) and
# the space surface is space-cadet's, with its coverage in that gem.
class CLITest < Space::ArchitectTest
  def test_version_forms_print_to_stdout_and_exit_0
    [["--version"], ["version"]].each do |argv|
      out = StringIO.new
      err = StringIO.new
      exit_code = Space::Architect::CLI.call(argv, out, err)
      assert_equal 0, exit_code, "#{argv.inspect} should exit 0"
      assert_equal Space::Architect::VERSION, out.string.chomp, "#{argv.inspect} should print VERSION to stdout"
      assert_empty err.string, "#{argv.inspect} should write nothing to stderr"
    end
  end

  def test_help_forms_print_listing_to_stdout_and_exit_0
    [[], ["--help"], ["-h"], ["help"]].each do |argv|
      out = StringIO.new
      err = StringIO.new
      exit_code = Space::Architect::CLI.call(argv, out, err)
      assert_equal 0, exit_code, "#{argv.inspect} should exit 0"
      assert_match(/\bworktree\b.*\[SUBCOMMAND\]/m, out.string, "#{argv.inspect} should list worktree group at root")
      assert_match(/\bvariant\b.*\[SUBCOMMAND\]/m, out.string, "#{argv.inspect} should list variant group at root")
      refute_match(/\bspace\b \[SUBCOMMAND\]/, out.string, "#{argv.inspect} must not list a space group — the forwarder is gone")
      assert_empty err.string, "#{argv.inspect} should write nothing to stderr"
    end
  end

  def test_unknown_command_exits_nonzero_with_usage_on_stderr
    out = StringIO.new
    err = StringIO.new
    error = assert_raises(SystemExit) { Space::Architect::CLI.call(["frozn"], out, err) }
    refute_equal 0, error.status, "unknown command must exit non-zero"
    assert_match(/Commands:/, err.string, "unknown command must render the usage listing on stderr")
  end

  def test_error_output_is_red_when_color_always
    out = StringIO.new
    err = StringIO.new
    assert_raises(SystemExit) { Space::Architect::CLI.call(["--color=always", "frozn"], out, err) }
    assert_match(/\e\[/, err.string, "error should be colored with --color=always")
  end

  def test_error_output_is_plain_when_color_never
    out = StringIO.new
    err = StringIO.new
    assert_raises(SystemExit) { Space::Architect::CLI.call(["--color=never", "frozn"], out, err) }
    refute_match(/\e\[/, err.string, "error should have no ANSI with --color=never")
  end

  # normalize_args (lib/space_architect/cli.rb) moves --color/--colors to the
  # end so dry-cli's command routing is not confused. All positions must route
  # to the same rendered usage (identical plain text) instead of an
  # "unknown option" failure. Positions: leading, mid (before a flag), trailing.
  def test_color_flag_positions_all_normalize_to_the_same_usage
    plain = color_usage(["frozn"])

    assert_equal plain, color_usage(["--color=always", "frozn"]), "leading --color=always must normalize"
    assert_equal plain, color_usage(["frozn", "--color=always"]), "trailing --color=always must normalize"
    assert_equal plain, color_usage(["--colors=never", "frozn"]), "leading --colors=never must normalize"
  end

  private

  # Renders the usage for argv with a color flag in `position`, stripped to
  # plain text so all positions compare equal regardless of color mode.
  def color_usage(argv)
    out = StringIO.new
    err = StringIO.new
    assert_raises(SystemExit) { Space::Architect::CLI.call(argv, out, err) }
    err.string.gsub(/\e\[[0-9;]*m/, "")
  end
end
