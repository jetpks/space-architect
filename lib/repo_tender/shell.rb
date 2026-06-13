# frozen_string_literal: true

require "open3"
require "async"
require "dry/monads"

module RepoTender
  # Thin Open3.capture3 wrapper that:
  #   * requires an ambient Async::Task (so subprocess I/O flows through
  #     Ruby's Fiber scheduler → kqueue on macOS and is non-blocking);
  #   * returns a Dry::Monads::Result — Success(stdout) on zero exit,
  #     Failure({argv:, stderr:, status:}) otherwise.
  #
  # Per AGENTS.md: no `async-process`. Per PRD §2: boundaries return
  # Result, exceptions are for programmer error only.
  class Shell
    extend Dry::Monads[:result]

    def self.run(*argv, chdir: nil, env: nil)
      raise ArgumentError, "Shell.run requires at least argv" if argv.empty?
      raise "Shell.run must be called inside an ambient Async::Task" unless Async::Task.current?

      full_env = env ? ENV.to_h.merge(env.transform_keys(&:to_s)) : nil
      opts = {}
      opts[:chdir] = chdir if chdir
      # Open3.capture3: env is a leading hash positional arg, not a kwarg.
      stdout, stderr, status = if full_env
        Open3.capture3(full_env, *argv, **opts)
      else
        Open3.capture3(*argv, **opts)
      end

      if status.success?
        Success(stdout)
      else
        Failure({argv: argv, stderr: stderr, status: status.exitstatus})
      end
    end
  end
end
