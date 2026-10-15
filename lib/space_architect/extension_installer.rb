# frozen_string_literal: true

require "open3"

module Space
  module Architect
    # Installs the architect-loop pi extension package through pi's own
    # mechanics. The gem owns the standing declaration (PACKAGE_SOURCE) and the
    # two-step sequence; pi owns settings.json and the rest — idempotent by
    # pi's semantics, safe to re-run.
    module ExtensionInstaller
      PACKAGE_SOURCE = "git:git@github.com:jetpks/pi-extensions.git"

      class << self
        # Runs `<pi_bin> install PACKAGE_SOURCE` then
        # `<pi_bin> update --extension PACKAGE_SOURCE`, in order, aborting on
        # the first failure. --extension (singular) on purpose: the gem
        # reconciles exactly the package it declares — not the operator's other
        # packages. Returns { source:, steps: [{cmd:, exit_code:, output:}] }.
        def install(pi_bin: "pi", env: ENV)
          steps = [
            run_step(pi_bin, ["install", PACKAGE_SOURCE], env),
            run_step(pi_bin, ["update", "--extension", PACKAGE_SOURCE], env)
          ]
          { source: PACKAGE_SOURCE, steps: steps }
        end

        private

        def run_step(pi_bin, args, env)
          cmd = [pi_bin, *args].join(" ")
          out, err, status = Open3.capture3(env, pi_bin, *args)
          output = out + err
          raise Space::Core::Error, "#{cmd} failed (exit #{status.exitstatus}):\n#{output}" unless status.success?

          { cmd: cmd, exit_code: status.exitstatus, output: output }
        rescue Errno::ENOENT
          raise Space::Core::Error,
            "#{pi_bin}: command not found — '#{cmd}' could not run. Install pi or check your PATH."
        end
      end
    end
  end
end
