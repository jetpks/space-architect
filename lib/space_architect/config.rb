# frozen_string_literal: true

require "yaml"
require "pathname"

module SpaceArchitect
  class Config
    DEFAULT_DATA = {
      "version" => 1,
      "spaces_dir" => "~/src/spaces",
      "evergreen_dir" => "~/src/evergreen",
      "default_provider" => "github.com",
      "default_organization" => nil,
      "git_clone_protocol" => "ssh"
    }.freeze
    EDITABLE_KEYS = %w[
      spaces_dir
      evergreen_dir
      default_provider
      default_organization
      git_clone_protocol
    ].freeze
    VALID_GIT_CLONE_PROTOCOLS = %w[ssh https].freeze

    attr_reader :path, :data, :env

    def self.default_path(env: ENV)
      XDG.config_home(env: env).join("space-architect", "config.yml")
    end

    def self.load(env: ENV, path: default_path(env: env))
      new(env:, path:).load
    end

    def initialize(env: ENV, path: self.class.default_path(env: env), data: nil)
      @path = Pathname.new(path)
      @env = env
      @data = data ? DEFAULT_DATA.merge(stringify_keys(data)) : DEFAULT_DATA.dup
    end

    def load
      @data = if path.exist?
                parsed = YAML.safe_load(path.read, aliases: false) || {}
                unless parsed.is_a?(Hash)
                  raise Error, "Config file must contain a YAML mapping: #{path}"
                end

                DEFAULT_DATA.merge(stringify_keys(parsed))
              else
                DEFAULT_DATA.dup
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

    def spaces_dir
      Pathname.new(XDG.expand_user(data.fetch("spaces_dir"), env: env))
    end

    def evergreen_dir
      value = normalized_value(data["evergreen_dir"])
      return nil unless value

      Pathname.new(XDG.expand_user(value, env: env))
    end

    def default_provider
      normalize_provider(data["default_provider"])
    end

    def default_organization
      normalized_value(data["default_organization"])
    end

    def git_clone_protocol
      protocol = normalized_value(data["git_clone_protocol"]) || "ssh"
      unless VALID_GIT_CLONE_PROTOCOLS.include?(protocol)
        raise Error, "Invalid git_clone_protocol '#{protocol}'. Expected one of: #{VALID_GIT_CLONE_PROTOCOLS.join(', ')}"
      end

      protocol
    end

    def set(key, value)
      normalized_key = key.to_s
      unless EDITABLE_KEYS.include?(normalized_key)
        raise InvalidConfigKeyError, "Unknown config key '#{key}'. Expected one of: #{EDITABLE_KEYS.join(', ')}"
      end

      data[normalized_key] = normalize_config_value(normalized_key, value)
      save
    end

    private

    def normalize_config_value(key, value)
      case key
      when "default_provider"
        normalize_provider(value)
      when "default_organization"
        normalized_value(value)
      when "git_clone_protocol"
        protocol = normalized_value(value)
        unless VALID_GIT_CLONE_PROTOCOLS.include?(protocol)
          raise Error, "Invalid git_clone_protocol '#{value}'. Expected one of: #{VALID_GIT_CLONE_PROTOCOLS.join(', ')}"
        end

        protocol
      else
        value
      end
    end

    def normalize_provider(value)
      normalized = normalized_value(value)
      return nil unless normalized

      normalized
        .delete_prefix("https://")
        .delete_prefix("http://")
        .delete_prefix("ssh://")
        .delete_suffix("/")
    end

    def normalized_value(value)
      normalized = value.to_s.strip
      normalized.empty? ? nil : normalized
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end
  end
end
