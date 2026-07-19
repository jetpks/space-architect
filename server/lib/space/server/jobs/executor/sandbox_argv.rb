# frozen_string_literal: true

require "dry/monads"

module Space
  module Server
    module Jobs
      class Executor
        # Builds the sandbox argv from a job spec + resolved image tag
        # (spike-pinned shape). Secret VALUES never appear here — secrets ride
        # as bare `-e NAME`, resolved only into the child's spawn environment.
        # Mounts must be absolute and non-escaping or the job is rejected.
        class SandboxArgv
          extend Dry::Monads[:result]

          HARNESS_ARGS = %w[--output-format stream-json --verbose].freeze

          # => Success(argv) | Failure(reason)
          def self.build(spec, image_tag)
            environment = spec["environment"] || {}
            permissions = environment["permissions"] || {}
            mounts      = permissions["mounts"] || []

            invalid = mounts.reject { |m| valid_mount?(m) }
            return Failure("invalid mount(s): #{invalid.join(', ')}") unless invalid.empty?

            argv = ["container", "run", "--rm"]
            (environment["env"] || {}).each { |k, v| argv << "-e" << "#{k}=#{v}" }
            (environment["secrets"] || []).each { |s| argv << "-e" << s["name"] }
            argv << "--network" << "none" unless permissions["network"]
            mounts.each { |m| argv << "-v" << m }
            argv << image_tag
            argv << "claude" << "-p" << spec["prompt"]
            Success(argv + HARNESS_ARGS)
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
