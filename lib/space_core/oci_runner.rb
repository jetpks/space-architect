# frozen_string_literal: true

require "pathname"
require "dry/monads"

module Space::Core
  class OciRunner
    include Dry::Monads[:result]

    AUTH_ENV = %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL].freeze

    def initialize(space:, env: ENV.to_h, interactive: true)
      @space = space
      @env = env
      @interactive = interactive
    end

    def image
      "#{space.id}:latest"
    end

    def mounts
      space.persist_paths.map do |guest|
        [space.path.join(".state" + guest), guest]
      end
    end

    def host_dirs
      mounts.map(&:first)
    end

    def command(extra = [])
      validated = validate_persist_paths(space.persist_paths)
      return validated if validated.failure?

      argv = [
        "container", "run", "--rm",
        *(@interactive ? ["-i", "-t"] : []),
        *auth_flags,
        *mount_flags,
        image,
        *extra
      ]
      Success(argv)
    end

    private

    attr_reader :space, :env, :interactive

    def auth_flags
      AUTH_ENV.each_with_object([]) do |var, flags|
        val = env[var]
        flags.push("-e", var) if val && !val.empty?
      end
    end

    def mount_flags
      mounts.each_with_object([]) do |(host, guest), flags|
        flags.push("-v", "#{host}:#{guest}")
      end
    end

    def validate_persist_paths(paths)
      paths.each do |path|
        unless Pathname.new(path).absolute?
          return Failure("persist path '#{path}' must be an absolute path")
        end
      end
      Success(paths)
    end
  end
end
