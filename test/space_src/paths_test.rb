# frozen_string_literal: true

require "space_src/test_helper"

class PathsTest < Minitest::Test
  include TestHelpers

  # G3: Paths resolves config/state/log/base under XDG envs, honoring
  # $XDG_CONFIG_HOME / $XDG_STATE_HOME overrides and the
  # ~/architect/src base default.

  def test_config_file_under_xdg_config_home_override
    with_paths do |env, paths|
      expected = File.join(env["XDG_CONFIG_HOME"], "repo-tender", "config.yaml")
      assert_equal expected, paths.config_file
    end
  end

  def test_state_file_under_xdg_state_home_override
    with_paths do |env, paths|
      expected = File.join(env["XDG_STATE_HOME"], "repo-tender", "state.yaml")
      assert_equal expected, paths.state_file
    end
  end

  def test_log_dir_under_xdg_state_home_override
    with_paths do |env, paths|
      expected = File.join(env["XDG_STATE_HOME"], "repo-tender", "logs")
      assert_equal expected, paths.log_dir
    end
  end

  def test_base_dir_default_is_under_home
    with_paths do |_env, paths|
      assert_equal File.expand_path("~/architect/src"), paths.base_dir
    end
  end

  def test_base_dir_override_is_honored
    with_paths(base_dir: "/custom/evergreen") do |_env, paths|
      assert_equal "/custom/evergreen", paths.base_dir
    end
  end

  def test_falls_back_to_xdg_defaults_when_envs_unset
    Dir.mktmpdir do |home|
      env = {"HOME" => home}
      paths = Space::Src::Paths.new(environment: env)
      assert_equal File.join(home, ".config"), paths.config_home
      assert_equal File.join(home, ".local", "state"), paths.state_home
    end
  end

  def test_ensure_creates_config_state_log_dirs
    with_paths do |_env, paths|
      paths.ensure!
      assert File.directory?(paths.config_dir), "config_dir not created"
      assert File.directory?(paths.state_dir), "state_dir not created"
      assert File.directory?(paths.log_dir), "log_dir not created"
    end
  end
end
