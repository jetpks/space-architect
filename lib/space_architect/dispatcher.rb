# frozen_string_literal: true

require "async/process"
require "pathname"

module SpaceArchitect
  class Dispatcher
    ALLOWED_TOOLS = "Read,Edit,Write,Grep,Glob,Bash,WebSearch,WebFetch"
    DISALLOWED_TOOLS = [
      "Bash(git commit:*)", "Bash(git push:*)", "Bash(git reset:*)",
      "Bash(git merge:*)", "Bash(git rebase:*)", "Bash(git checkout:*)",
      "Bash(git branch:*)"
    ].join(",")

    def initialize(model: "claude-sonnet-4-6", max_turns: 200, claude_bin: nil)
      @model      = model
      @max_turns  = max_turns
      @claude_bin = claude_bin || ENV.fetch("ARCHITECT_CLAUDE_BIN", "claude")
    end

    def run(prompt_path:, run_log_path:, chdir:)
      prompt_path  = Pathname.new(prompt_path)
      run_log_path = Pathname.new(run_log_path)

      File.open(prompt_path, "r") do |prompt_io|
        File.open(run_log_path, "w") do |log|
          status = Sync do
            Async::Process.spawn(*argv, chdir: chdir.to_s, in: prompt_io, out: log, err: log)
          end
          status.exitstatus
        end
      end
    end

    private

    def argv
      [
        @claude_bin, "-p",
        "--model", @model,
        "--permission-mode", "acceptEdits",
        "--allowedTools", ALLOWED_TOOLS,
        "--disallowedTools", DISALLOWED_TOOLS,
        "--output-format", "stream-json",
        "--verbose",
        "--max-turns", @max_turns.to_s
      ]
    end
  end
end
