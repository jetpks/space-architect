# frozen_string_literal: true

require_relative "harness"

module Space::Architect
  # Thin backward-compat wrapper around Harness::ClaudeCodeHarness.
  # Existing callers that construct Dispatcher.new(...).run(...) continue to work byte-for-byte.
  class Dispatcher
    # Keep constants here so any code referencing Dispatcher::ALLOWED_TOOLS still works.
    ALLOWED_TOOLS    = Harness::ClaudeCodeHarness::ALLOWED_TOOLS
    DISALLOWED_TOOLS = Harness::ClaudeCodeHarness::DISALLOWED_TOOLS

    def initialize(model: "claude-sonnet-4-6", max_turns: 200, claude_bin: nil)
      @harness = Harness::ClaudeCodeHarness.new(model: model, max_turns: max_turns, bin: claude_bin)
    end

    def run(prompt_path:, run_log_path:, chdir:)
      @harness.run(prompt_path: prompt_path, run_log_path: run_log_path, chdir: chdir)
    end

    def run_detached(prompt_path:, run_log_path:, chdir:)
      @harness.run_detached(prompt_path: prompt_path, run_log_path: run_log_path, chdir: chdir)
    end
  end
end
