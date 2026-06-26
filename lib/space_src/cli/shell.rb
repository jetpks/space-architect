# frozen_string_literal: true

require "space_src/cli"
require "space_src/shell_integration"

module Space::Src
  module CLI
    module Shell
      class Init < Dry::CLI::Command
        desc "Print shell integration script"
        argument :shell_name, required: true, desc: "Shell name (e.g. fish)"

        def call(shell_name:, **)
          out.puts ShellIntegration.for(shell_name)
          CLI.record_outcome(Outcome.new(exit_code: 0))
        rescue => e
          err.puts "src shell init: #{e.message}"
          CLI.record_outcome(Outcome.new(exit_code: 1))
        end
      end
    end
  end
end

Space::Src::CLI::Registry.register "shell" do |prefix|
  prefix.register "init", Space::Src::CLI::Shell::Init
end
