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
          config = Config::Store.load(paths.config_file).success

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
      end
    end
  end
end

RepoTender::CLI::Registry.register "sync", RepoTender::CLI::Sync::Run
