# frozen_string_literal: true

require "pathname"
require "dry/monads"

module Space::Core
  class OciRunner
    include Dry::Monads[:result]

    # Always-forwarded substrate auth (the in-image architect/claude reach for these).
    # Payload-specific vars are declared per-space via `run.env:` or the --env flag.
    AUTH_ENV = %w[ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL].freeze

    def initialize(space:, env: ENV.to_h, interactive: true, env_vars: [])
      @space = space
      @env = env
      @interactive = interactive
      @env_vars = (space.run_env + Array(env_vars)).map(&:to_s)
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
        *env_flags,
        *mount_flags,
        image,
        *extra
      ]
      Success(argv)
    end

    # Explicitly-requested vars (run.env: + --env) that are unset/empty in the host
    # env, so the caller can warn — silence here would let a missing key fail opaquely
    # inside the guest. AUTH_ENV is opportunistic and intentionally excluded.
    def missing_env
      @env_vars.uniq.reject { |var| present?(var) }
    end

    private

    attr_reader :space, :env, :interactive

    # Bare `-e VAR` passthrough (no =value on the command line, so the secret never
    # lands in argv/ps): substrate auth first, then the space's declared payload vars.
    def env_flags
      (AUTH_ENV + @env_vars).uniq.each_with_object([]) do |var, flags|
        flags.push("-e", var) if present?(var)
      end
    end

    def present?(var)
      val = env[var]
      val && !val.empty?
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
