# frozen_string_literal: true

require_relative "test_helper"

class XDGConfigStateTest < SpaceArchitectTest
  def test_config_and_state_use_xdg_paths
    setup = temp_env
    env = setup.fetch(:env)

    assert_equal File.join(env["XDG_CONFIG_HOME"], "space-architect", "config.yml"),
                 SpaceArchitect::Config.default_path(env: env).to_s
    assert_equal File.join(env["XDG_STATE_HOME"], "space-architect", "state.yml"),
                 SpaceArchitect::State.default_path(env: env).to_s
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_config_expands_spaces_dir_against_env_home
    setup = temp_env
    env = setup.fetch(:env)
    config = SpaceArchitect::Config.new(env: env, data: {})

    assert_equal File.join(env["HOME"], "architect", "spaces"), config.spaces_dir.to_s
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_paths_derive_from_base_dir
    env = {"HOME" => "/tmp/fh"}
    default_config = SpaceArchitect::Config.new(env: env, data: {})
    assert_equal "/tmp/fh/architect", default_config.base_dir.to_s
    assert_equal "/tmp/fh/architect/spaces", default_config.spaces_dir.to_s
    assert_equal "/tmp/fh/architect/src", default_config.src_dir.to_s

    override_config = SpaceArchitect::Config.new(env: env, data: {"spaces_dir" => "~/custom-spaces"})
    assert_equal "/tmp/fh/custom-spaces", override_config.spaces_dir.to_s

    disabled_config = SpaceArchitect::Config.new(env: env, data: {"src_dir" => ""})
    assert_nil disabled_config.src_dir
  end

  def test_state_tracks_current_and_recent_spaces
    setup = temp_env
    env = setup.fetch(:env)
    state = SpaceArchitect::State.new(env: env)

    state.touch_current("20260531-one")
    state.touch_current("20260531-two")
    state.touch_current("20260531-one")

    loaded = SpaceArchitect::State.load(env: env)
    assert_equal "20260531-one", loaded.current_space
    assert_equal ["20260531-one", "20260531-two"], loaded.recent
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end
end
