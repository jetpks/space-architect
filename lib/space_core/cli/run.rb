# frozen_string_literal: true

require "fileutils"
require_relative "../oci_runner"

module Space::Core::CLI
class Run < BaseCommand
  desc "Run the packed OCI image for the current space (auth injected at runtime). Pass a command and its arguments after `--` so they forward as separate argv tokens"

  argument :command, type: :array, required: false, desc: "Command to run in the container (default: login shell). Use `--` to pass a command with arguments, e.g. `space run -- hermes -z \"hello\"`"
  option :tty, type: :boolean, default: nil, desc: "Force interactive TTY (default: auto-detect)"
  option :env, type: :array, desc: "Host env var to forward into the container (repeatable; adds to run.env)"
  example "-- hermes -z \"What is 17 plus 4?\"   # `--` forwards the command and its args as separate tokens (a quoted multi-word command arrives as one token and fails in-guest)"

  def call(command: [], tty: nil, env: [], **opts)
    setup_terminal(**opts.slice(:color, :colors))
    handle_errors do
      result = store.current.bind do |space|
        runner = Space::Core::OciRunner.new(
          space: space, interactive: tty.nil? ? CLI.tty?(out) : tty, env_vars: env
        )
        runner.command(command).fmap { |argv| { argv: argv, runner: runner } }
      end
      render(result) do |r|
        r[:runner].host_dirs.each { |d| FileUtils.mkdir_p(d) }
        warn_missing_env(r[:runner].missing_env)
        terminal.say "Running: #{r[:argv].join(' ')}"
        out.flush # Kernel.exec replaces the process without flushing buffered IO
        Kernel.exec(*r[:argv])
      end
    end
  end

  private

  # A requested var absent from the host env is almost always a forgotten export;
  # forwarding silently omits it and the payload fails opaquely in-guest. Warn, don't fail.
  def warn_missing_env(missing)
    return if missing.empty?

    terminal.error("Warning: requested env not set on host, not forwarded: #{missing.join(', ')}")
  end
end
end
