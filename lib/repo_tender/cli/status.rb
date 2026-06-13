# frozen_string_literal: true

require "repo_tender/cli"

module RepoTender
  module CLI
    # `status` command: render a per-repo evergreen table from
    # State::Store. Per G5, the rows must include each repo key
    # with status, last_synced_at, and default_branch.
    module Status
      class Show < Dry::CLI::Command
        desc "Show the per-repo evergreen status table (from $XDG_STATE_HOME/repo-tender/state.yaml)"

        def call(**)
          paths = CLI.make_paths
          state = State::Store.load(paths.state_file).success

          if state.repos.empty?
            out.puts "(no repos in state — run `repo-tender sync` to populate)"
            return CLI.record_outcome(Outcome.new(exit_code: 0))
          end

          # Tab-separated columns. The G5 assertion is on captured
          # stdout containing each repo key and its status string —
          # tab-separated is the most assertion-friendly (no width
          # padding complexity, no ANSI codes).
          out.puts ["REPO", "STATUS", "DEFAULT_BRANCH", "LAST_SYNCED_AT", "LAST_FETCH_AT"].join("\t")
          state.repos.keys.sort.each do |key|
            r = state.repos[key]
            out.puts [
              key,
              r.status.to_s,
              r.default_branch.to_s,
              format_time(r.last_synced_at),
              format_time(r.last_fetch_at)
            ].join("\t")
          end
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end

        private

        def format_time(t)
          return "" if t.nil?
          t.respond_to?(:iso8601) ? t.iso8601 : t.to_s
        end
      end
    end
  end
end

RepoTender::CLI::Registry.register "status", RepoTender::CLI::Status::Show
