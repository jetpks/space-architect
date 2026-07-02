# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class CoreCommandsTest < Space::ArchitectTest
  def test_short_command_passthrough
    assert_equal "cd ~/path", Space::Core::Commands.wrap("cd ~/path")
  end

  def test_short_flag_command_passthrough
    assert_equal "git push -u origin branch", Space::Core::Commands.wrap("git push -u origin branch")
  end

  def test_wraps_at_double_dash_flag_boundaries
    result = Space::Core::Commands.wrap(%(gh pr create --base main --head slug --title "T" --body-file ~/f))
    lines = result.split("\n")
    assert_equal 5, lines.size
    assert_equal %(gh pr create \\), lines[0]
    assert_equal %(  --base main \\), lines[1]
    assert_equal %(  --head slug \\), lines[2]
    assert_equal %(  --title "T" \\), lines[3]
    assert_equal "  --body-file ~/f", lines[4]
  end

  def test_continuation_lines_have_two_space_indent
    result = Space::Core::Commands.wrap("gh pr create --base main --body-file ~/f")
    result.split("\n")[1..].each { |l| assert_match(/\A  /, l) }
  end

  def test_all_but_last_continuation_line_ends_with_backslash
    result = Space::Core::Commands.wrap("gh pr create --base main --head slug --body-file ~/f")
    lines = result.split("\n")
    lines[0..-2].each { |l| assert_match(/ \\$/, l) }
    refute_match(/ \\$/, lines.last)
  end

  def test_short_flag_stays_on_base_line
    result = Space::Core::Commands.wrap("gh issue create -R org/repo --title \"T\" --body-file ~/f")
    lines = result.split("\n")
    assert_match(/\Agh issue create -R org\/repo \\/, lines[0])
    assert_equal "  --title \"T\" \\", lines[1]
    assert_equal "  --body-file ~/f", lines[2]
  end

  def test_wrapped_output_is_bash_n_valid
    result = Space::Core::Commands.wrap(
      %(gh pr create --base main --head project/slug --title "Space Title" --body-file ~/path/to/file.md)
    )
    _out, _err, status = Open3.capture3("bash", "-n", stdin_data: result)
    assert status.success?, "wrapped command must pass bash -n"
  end

  def test_single_flag_command_wraps
    result = Space::Core::Commands.wrap("gh pr create --base main")
    lines = result.split("\n")
    assert_equal 2, lines.size
    assert_equal "gh pr create \\", lines[0]
    assert_equal "  --base main", lines[1]
  end
end
