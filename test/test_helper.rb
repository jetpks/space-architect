# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "minitest/autorun"
require_relative "../lib/space_architect"

class SpaceArchitectTest < Minitest::Test
  def invoke(*argv)
    out = StringIO.new
    err = StringIO.new
    SpaceArchitect::CLI.call(argv.flatten, out, err)
    [out.string, err.string]
  end
  def with_env(vars)
    original = vars.each_key.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    original&.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  def temp_env
    root = Dir.mktmpdir("project-spaces-test")
    {
      root: root,
      env: {
        "HOME" => File.join(root, "home"),
        "XDG_CONFIG_HOME" => File.join(root, "xdg-config"),
        "XDG_STATE_HOME" => File.join(root, "xdg-state")
      }
    }
  end

  def fixed_time
    Time.new(2026, 5, 31, 13, 48, 0, "-06:00")
  end

  def build_store(env:, now: -> { fixed_time })
    config = Space::Core::Config.new(
      env: env,
      data: { "version" => 1 }
    )
    state = Space::Core::State.new(env: env)
    Space::Core::SpaceStore.new(config: config, state: state, now: now)
  end
end
