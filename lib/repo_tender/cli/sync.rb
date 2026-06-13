# frozen_string_literal: true

require "dry/monads"
require "repo_tender/cli"
require "repo_tender/cli/repo"  # for Repo::Helpers.parse_ref

module RepoTender
  module CLI
    # `sync` command: invoke Sync::Engine over the full config, or
    # scope to a single repo with --repo.
    #
    # Scoping is implemented at the CLI layer (per gate G4): the
    # CLI builds a filtered Config (Config::Store.with(config,
    # repos: [match], orgs: [])) and passes it to the unchanged
    # engine. Sync::Engine#call is (config:, paths:) — there is no
    # scoping parameter on the engine, and the spec forbids editing
    # sync/engine.rb in this slice.
    module Sync
      class Run < Dry::CLI::Command
        desc "Run one sync pass (use --repo to scope to a single tracked repo)"
        option :repo, desc: "Scope to a single tracked repo (host/owner/name)"

        def call(repo: nil, **)
          paths = CLI.make_paths
          paths.ensure!
          config = Config::Store.load(paths.config_file).success

          # Log rotation pre-step (slice-4 gate G5). launchd owns
          # the stdout/stderr redirect via StandardOutPath /
          # StandardErrorPath; the sync process rotates those
          # files at the start of each run so the previous run's
          # log doesn't grow unbounded. The rotator renames the
          # file to a timestamped archive (preserving bytes); the
          # current process's inherited fd still points to the
          # renamed file, so writes during this run succeed.
          # launchd opens a fresh file at the original path on
          # the next spawn. No-op when the log is missing or
          # under-threshold (sync tests in G4 stay green).
          rotate_plist_logs(paths)
          if repo
            target = scope_target(repo)
            return fail_with(self, "invalid repo reference: #{repo.inspect} (expected host/owner/name)") if target.failure?

            match = target.success
            found = config.repos.find { |r| Repo::Helpers.same_repo?(r, match) }
            if found.nil?
              return fail_with(self, "no such tracked repo: #{Repo::Helpers.format_ref(match)}")
            end
            # Filtered config: only the one matched repo, no orgs
            # (org expansion would discover other repos — that's
            # exactly the G4 "other repo gets no state row" test
            # path, so we explicitly empty orgs here).
            config = Config::Store.with(config, repos: [found], orgs: [])
            out.puts "scoping sync to: #{Repo::Helpers.format_ref(found)}"
          end

          result = RepoTender::Sync::Engine.new.call(config: config, paths: paths)
          if result.failure?
            return fail_with(self, "sync failed: #{format_failure(result.failure)}")
          end

          new_state = result.success
          n = new_state.repos.size
          out.puts "synced #{n} repo(s)"
          CLI.record_outcome(Outcome.new(exit_code: 0))
        end

        private

        def scope_target(repo)
          Repo::Helpers.parse_ref(repo)
        end

        def format_failure(f) = f.is_a?(Hash) ? f.inspect : f.to_s

        def fail_with(cmd, msg)
          cmd.send(:err).puts msg
          RepoTender::CLI.record_outcome(Outcome.new(exit_code: 1, message: msg))
        end

        # Default log-rotation threshold: 10 MiB. Tunable via the
        # env var `REPO_TENDER_LOG_MAX_BYTES` (introspection /
        # ops escape hatch). The LogRotator itself is unit-tested
        # with an injected threshold (gate G5).
        DEFAULT_LOG_MAX_BYTES = 10 * 1024 * 1024

        def rotate_plist_logs(paths)
          threshold = Integer(ENV["REPO_TENDER_LOG_MAX_BYTES"] || DEFAULT_LOG_MAX_BYTES)
          label = Launchd::Agent::DEFAULT_LABEL
          [File.join(paths.log_dir, "#{label}.out.log"),
            File.join(paths.log_dir, "#{label}.err.log")].each do |p|
            RepoTender::LogRotator.call(p, threshold_bytes: threshold)
          end
        end
      end
    end
  end
end

RepoTender::CLI::Registry.register "sync", RepoTender::CLI::Sync::Run
