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
    config = SpaceArchitect::Config.new(env: env, data: { "spaces_dir" => "~/src/spaces" })

    assert_equal File.join(env["HOME"], "src", "spaces"), config.spaces_dir.to_s
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
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
