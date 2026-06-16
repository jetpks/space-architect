# frozen_string_literal: true

require "yaml"
require "pathname"

module SpaceCadet
  class State
    DEFAULT_DATA = {
      "version" => 1,
      "current_space" => nil,
      "recent" => []
    }.freeze

    attr_reader :path, :data, :env

    def self.default_path(env: ENV)
      XDG.state_home(env: env).join("space-cadet", "state.yml")
    end

    def self.load(env: ENV, path: default_path(env: env))
      new(env:, path:).load
    end

    def initialize(env: ENV, path: self.class.default_path(env: env), data: nil)
      @path = Pathname.new(path)
      @env = env
      @data = data ? default_data.merge(stringify_keys(data)) : default_data
    end

    def load
      @data = if path.exist?
                parsed = YAML.safe_load(path.read, aliases: false) || {}
                unless parsed.is_a?(Hash)
                  raise Error, "State file must contain a YAML mapping: #{path}"
                end

                default_data.merge(stringify_keys(parsed))
              else
                default_data
              end
      self
    end

    def ensure_exists!
      save unless path.exist?
      self
    end

    def save
      AtomicWrite.write(path, YAML.dump(data))
      self
    end

    def current_space
      data["current_space"]
    end

    def current_space=(space_id)
      data["current_space"] = space_id
    end

    def recent
      Array(data["recent"])
    end

    def touch_current(space_id)
      self.current_space = space_id
      touch_recent(space_id)
    end

    def touch_recent(space_id)
      data["recent"] = ([space_id] + recent).compact.uniq.first(20)
      save
    end

    private

    def default_data
      DEFAULT_DATA.merge("recent" => [])
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end
  end
end
