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
        # A cidfile records the container ID so the stop path can act on the
        # container itself — client signals don't stop it (I09 P5).
        class SandboxArgv
          extend Dry::Monads[:result]

          HARNESS_ARGS          = %w[--output-format stream-json --verbose].freeze
          PI_FLAGS              = %w[-p --mode json --no-session --no-approve].freeze
          OPENCODE_ARGS         = %w[--format json].freeze
          BASE_URL_ENV          = "ANTHROPIC_BASE_URL"
          API_KEY_ENV           = "ANTHROPIC_API_KEY"
          NO_BACKEND_ENV_TYPES  = %w[pi opencode].freeze

          # => Success(argv) | Failure(reason)
          def self.build(spec, image_tag, cidfile: nil)
            harness     = spec["harness"] || {}
            backend     = harness["backend"] || {}
            environment = spec["environment"] || {}
            permissions = environment["permissions"] || {}
            mounts      = permissions["mounts"] || []
            workdir     = spec.dig("workspace", "dir")

            invalid = mounts.reject { |m| valid_mount?(m) }
            return Failure("invalid mount(s): #{invalid.join(', ')}") unless invalid.empty?

            # The harness backend (base_url/api_key_ref) is claude's Anthropic-gateway
            # transport — pi and opencode each reach their gateway another way (a
            # pi extension / opencode config riding environment.files), so neither
            # gets ANTHROPIC_BASE_URL/API_KEY env injection (declared
            # environment.env/secrets still ride either way).
            env_backend = NO_BACKEND_ENV_TYPES.include?(harness["type"]) ? {} : backend

            argv = ["container", "run", "--rm"]
            argv << "--cidfile" << cidfile if cidfile
            env_pairs(environment, env_backend).each { |k, v| argv << "-e" << "#{k}=#{v}" }
            secret_names(environment, env_backend).each { |name| argv << "-e" << name }
            argv << "--network" << "none" unless permissions["network"]
            mounts.each { |m| argv << "-v" << m }
            argv << "--workdir" << workdir if workdir
            argv << image_tag
            Success(argv + harness_tail(harness, spec["prompt"]))
          end

          def self.harness_tail(harness, prompt)
            case harness["type"]
            when "pi" then pi_tail(harness, prompt)
            when "opencode" then opencode_tail(harness, prompt)
            else claude_tail(harness, prompt)
            end
          end

          def self.pi_tail(harness, prompt)
            tail = ["pi"] + PI_FLAGS
            tail += ["--model", harness["model"]] if harness["model"]
            tail << prompt
            tail + Array(harness["args"])
          end

          # opencode's headless surface: `opencode run <message> [--model
          # provider/model] --format json`, verified live against 1.17.13 (server
          # lane report has the full recipe). Model reaches opencode via its own
          # config (environment.files), not this argv, the same seam pi uses.
          def self.opencode_tail(harness, prompt)
            tail = ["opencode", "run", prompt]
            tail += ["--model", harness["model"]] if harness["model"]
            tail + OPENCODE_ARGS + Array(harness["args"])
          end

          def self.claude_tail(harness, prompt)
            tail = ["claude", "-p", prompt]
            tail += ["--model", harness["model"]] if harness["model"]
            tail + HARNESS_ARGS + Array(harness["args"])
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
