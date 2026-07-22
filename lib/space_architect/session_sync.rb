# frozen_string_literal: true

require_relative "session_sync/session_id"
require_relative "session_sync/cursor"
require_relative "session_sync/runner"
require_relative "session_sync/plist"
require_relative "session_sync/bin_path"

module Space::Architect
  # Session-sync rail's laptop half: scans ~/.pi/agent/sessions/**/*.jsonl and
  # ~/.claude/projects/**/*.jsonl for conversation files, uploads new/grown
  # ones to a space-server via ConversationsClient, and installs a per-user
  # launchd agent that runs the sync on an interval. Opencode (sqlite) is out
  # of scope for this rail.
  module SessionSync
    LABEL = "io.github.jetpks.space-architect.session-sync"
    APP_NAME = "space-architect"
    TOKEN_ENV = "SPACE_ARCHITECT_INGEST_TOKEN"

    module_function

    # The one op-read seam under lib/: resolves an op:// ref via `op read`.
    # Shared by ConversationsClient's default op_resolver and
    # Sessions::Agent::Install (both test-injectable around this call).
    def resolve_token(ref)
      value = IO.popen(["op", "read", ref], &:read)
      raise Space::Core::Error, "op read failed for #{ref}" unless $?.success?

      value.chomp
    end

    def state_dir(env: ENV)
      File.join(Space::Core::XDG.state_home(env: env).to_s, APP_NAME)
    end

    def default_state_file(env: ENV)
      File.join(state_dir(env: env), "session-sync.yaml")
    end

    def default_pi_root(env: ENV)
      File.join(Space::Core::XDG.home(env: env), ".pi", "agent", "sessions")
    end

    def default_claude_root(env: ENV)
      File.join(Space::Core::XDG.home(env: env), ".claude", "projects")
    end

    def log_dir(env: ENV)
      File.join(state_dir(env: env), "logs")
    end

    def launch_agents_dir(env: ENV)
      File.join(Space::Core::XDG.home(env: env), "Library", "LaunchAgents")
    end
  end
end
