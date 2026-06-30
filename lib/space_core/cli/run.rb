# frozen_string_literal: true

require "fileutils"
require_relative "../oci_runner"

module Space::Core::CLI
class Run < BaseCommand
  desc "Run the packed OCI image for the current space (auth injected at runtime)"

  argument :command, type: :array, required: false, desc: "Command to run in the container (default: login shell)"
  option :tty, type: :boolean, default: nil, desc: "Force interactive TTY (default: auto-detect)"

  def call(command: [], tty: nil, **opts)
    setup_terminal(**opts.slice(:color, :colors))
    handle_errors do
      result = store.current.bind do |space|
        runner = Space::Core::OciRunner.new(space: space, interactive: tty.nil? ? CLI.tty?(out) : tty)
        runner.command(command).fmap { |argv| { argv: argv, runner: runner } }
      end
      render(result) do |r|
        r[:runner].host_dirs.each { |d| FileUtils.mkdir_p(d) }
        terminal.say "Running: #{r[:argv].join(' ')}"
        out.flush # Kernel.exec replaces the process without flushing buffered IO
        Kernel.exec(*r[:argv])
      end
    end
  end
end
end
