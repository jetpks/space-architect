# frozen_string_literal: true

require_relative "../test_helper"

class CLIRunTest < Space::ArchitectTest
  def test_run_appears_in_space_help
    out = StringIO.new
    err = StringIO.new
    Space::Core::CLI.call([], out, err)

    assert_match(/\brun\b/, out.string, "space --help should list the run command")
  end

  def test_run_appears_in_architect_space_help
    out = StringIO.new
    err = StringIO.new
    Space::Architect::CLI.call(["space"], out, err)

    assert_match(/\brun\b/, out.string, "architect space --help should list the run command")
  end
end
