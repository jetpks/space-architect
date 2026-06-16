# frozen_string_literal: true

require "pathname"

module SpaceCadet
  module XDG
    module_function

    def config_home(env: ENV)
      Pathname.new(env.fetch("XDG_CONFIG_HOME", File.join(home(env: env), ".config")))
    end

    def state_home(env: ENV)
      Pathname.new(env.fetch("XDG_STATE_HOME", File.join(home(env: env), ".local", "state")))
    end

    def home(env: ENV)
      env.fetch("HOME", Dir.home)
    end

    def expand_user(path, env: ENV)
      value = path.to_s

      if value == "~"
        home(env: env)
      elsif value.start_with?("~/")
        File.join(home(env: env), value[2..])
      else
        File.expand_path(value)
      end
    end
  end
end
