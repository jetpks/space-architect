# frozen_string_literal: true

require_relative "test_helper"

class CLISrcTest < SpaceArchitectTest
  def test_src_help_prints_pristine_usage_and_exits_0
    out = StringIO.new
    err = StringIO.new
    code = SpaceArchitect::CLI.call(["src"], out, err)
    assert_equal 0, code
    assert_match(/Commands:/, out.string)
    assert_match(/sync/, out.string)
  end

  def test_src_help_flag_prints_pristine_usage_and_exits_0
    out = StringIO.new
    err = StringIO.new
    code = SpaceArchitect::CLI.call(["src", "--help"], out, err)
    assert_equal 0, code
    assert_match(/Commands:/, out.string)
    assert_match(/sync/, out.string)
  end

  def test_src_version_prints_pristine_version_and_exits_0
    out = StringIO.new
    err = StringIO.new
    code = SpaceArchitect::CLI.call(["src", "version"], out, err)
    assert_equal 0, code
    assert_equal Space::Src::VERSION, out.string.chomp
  end

  def test_src_version_flag_prints_pristine_version_and_exits_0
    out = StringIO.new
    err = StringIO.new
    code = SpaceArchitect::CLI.call(["src", "--version"], out, err)
    assert_equal 0, code
    assert_equal Space::Src::VERSION, out.string.chomp
  end

  def test_src_status_dispatches_to_pristine_and_returns_0
    out = StringIO.new
    err = StringIO.new
    Dir.mktmpdir do |d|
      Thread.current[:space_src_cli_env] = {
        "HOME" => "#{d}/h",
        "XDG_CONFIG_HOME" => "#{d}/c",
        "XDG_STATE_HOME" => "#{d}/s"
      }
      code = SpaceArchitect::CLI.call(["src", "status"], out, err)
      assert_equal 0, code
      assert_match(/no repos in state/, out.string)
    ensure
      Thread.current[:space_src_cli_env] = nil
    end
  end

  def test_src_unknown_token_routes_through_fuzzy_nav_and_returns_1
    # Single unknown token is now a bare nav query (not dry-cli routing).
    # No match → no-match message on stderr, returns exit code 1 (not SystemExit).
    out = StringIO.new
    err = StringIO.new
    Dir.mktmpdir do |d|
      Thread.current[:space_src_cli_env] = {
        "HOME" => d,
        "XDG_CONFIG_HOME" => "#{d}/.config",
        "XDG_STATE_HOME" => "#{d}/.local/state"
      }
      code = SpaceArchitect::CLI.call(["src", "zqxnomatch"], out, err)
      assert_equal 1, code
      assert_includes err.string, "zqxnomatch"
    ensure
      Thread.current[:space_src_cli_env] = nil
    end
  end
end
