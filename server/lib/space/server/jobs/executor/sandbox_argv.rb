# frozen_string_literal: true

require "dry/monads"

module Space
  module Server
    module Jobs
      class Executor
        # Builds the sandbox argv from a job spec + resolved image tag
        # (spike-pinned shape). Secret VALUES never appear here — secrets ride
        # as bare `-e NAME`, resolved only into the child's spawn environment;
        # the harness backend (base_url / api_key_ref / model / args) is applied
        # the same way, backend winning any environment.env name collision.
        # Mounts must be absolute and non-escaping or the job is rejected.
        class SandboxArgv
          extend Dry::Monads[:result]

          HARNESS_ARGS = %w[--output-format stream-json --verbose].freeze
          BASE_URL_ENV = "ANTHROPIC_BASE_URL"
          API_KEY_ENV  = "ANTHROPIC_API_KEY"

          # => Success(argv) | Failure(reason)
          def self.build(spec, image_tag)
            harness     = spec["harness"] || {}
            backend     = harness["backend"] || {}
            environment = spec["environment"] || {}
            permissions = environment["permissions"] || {}
            mounts      = permissions["mounts"] || []

            invalid = mounts.reject { |m| valid_mount?(m) }
            return Failure("invalid mount(s): #{invalid.join(', ')}") unless invalid.empty?

            argv = ["container", "run", "--rm"]
            env_pairs(environment, backend).each { |k, v| argv << "-e" << "#{k}=#{v}" }
            secret_names(environment, backend).each { |name| argv << "-e" << name }
            argv << "--network" << "none" unless permissions["network"]
            mounts.each { |m| argv << "-v" << m }
            argv << image_tag
            argv << "claude" << "-p" << spec["prompt"]
            argv << "--model" << harness["model"] if harness["model"]
            Success(argv + HARNESS_ARGS + Array(harness["args"]))
          end

          # environment.env with backend-derived pairs applied last: the backend
          # owns any name it derives, so a colliding declared value is dropped
          # (an api-key collision falls to the name-only secret transport below).
          def self.env_pairs(environment, backend)
            pairs = environment["env"] || {}
            pairs = pairs.except(API_KEY_ENV) if backend["api_key_ref"]
            backend["base_url"] ? pairs.merge(BASE_URL_ENV => backend["base_url"]) : pairs
          end

          # Names riding bare `-e NAME` (values only ever in the spawn env):
          # declared secrets plus the backend api key when a ref is present.
          def self.secret_names(environment, backend)
            names = (environment["secrets"] || []).map { |s| s["name"] }
            names << API_KEY_ENV if backend["api_key_ref"]
            names.uniq
          end

          # A mount spec is SRC[:DST[:OPTS]]; both path components must be
          # absolute and free of `..` traversal.
          def self.valid_mount?(mount)
            paths = mount.to_s.split(":").first(2)
            !paths.empty? && paths.all? do |path|
              path.start_with?("/") && !path.split("/").include?("..")
            end
          end
        end
      end
    end
  end
end
