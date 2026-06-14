# frozen_string_literal: true

require "fileutils"
require "time"
require "async"
require "async/barrier"
require "async/semaphore"
require "dry/monads"
require "repo_tender/config/model"
require "repo_tender/scm/git"
require "repo_tender/forge/github"
require "repo_tender/state/store"
require "repo_tender/paths"
require "repo_tender/sync/repo_plan"

module RepoTender
  module Sync
    # The sync engine: one run that brings every tracked repo to the
    # evergreen invariant (PRD §3.3). Splits observation (RepoPlan)
    # from execution (this class). Bounded by Async::Semaphore
    # (config.concurrency) inside one Sync{} block. A single repo's
    # Failure does NOT abort the run — it is captured, the state row
    # is written as status: error, and the run continues.
    #
    # Slice 2 gate wiring:
    #   G7  — Async::Semaphore(concurrency) bounds the in-flight count.
    #   G8  — every processed repo gets a state row; failures are
    #         recorded with status: error + last_error.
    #   G9  — second run on a fresh set performs no network calls
    #         (the :skip_fresh plan short-circuits the SCM.fetch).
    #   G10 — OrgRef expansion via the injected forge; an org-list
    #         Failure is recorded and does not abort the run.
    class Engine
      extend Dry::Monads[:result]

      # `Success` and `Failure` are used inside the `call` instance
      # method (via the `Sync{}` block). Per Slice 1 convention
      # (see SCM::Client / SCM::Git / Shell), we use the fully-
      # qualified `Dry::Monads::Success(...)` from inside instance
      # methods. The `extend` is kept so class-level callers (tests,
      # future helpers) can use the short form.

      # Default clone URL: scp-like SSH form `git@<host>:<owner>/<name>.git`.
      # SSH uses the user's configured SSH keys (default
      # `~/.ssh/id_rsa`/whatever `~/.ssh/config` resolves) with no
      # interactive `Username for 'https://github.com':` prompt — the
      # field defect Slice 6 fixed (the previous HTTPS default made
      # a missing-repo clone prompt for credentials). This is the
      # seam the Slice 2 disagreement-#6 ruling anticipated ("legit
      # future seam (ssh/token)"). No new config field is added in
      # this slice — the transport flip is on the default builder
      # only; tests can still inject a different builder (e.g.
      # file:// for a local bare remote in the G6 missing-path test).
      DEFAULT_URL_BUILDER = ->(ref) { "git@#{ref.host}:#{ref.owner}/#{ref.name}.git" }.freeze

      def initialize(scm: SCM::Git.new, forge: Forge::GitHub.new,
        clock: -> { Time.now }, url_builder: DEFAULT_URL_BUILDER)
        @scm = scm
        @forge = forge
        @clock = clock
        @url_builder = url_builder
      end

      # Runs one sync pass.
      # @param config [Config::Config] the validated config struct
      # @param paths  [Paths]         the XDG paths object
      # @return [Dry::Monads::Result<State::Store::State>]
      def call(config:, paths:)
        Sync do |task|
          semaphore = Async::Semaphore.new(config.concurrency, parent: task)
          barrier = Async::Barrier.new

          # State is loaded once at the start (or initialized empty for
          # a missing state.yaml). A new State object is built from
          # the run's outcomes and written atomically at the end. Per-
          # repo state rows that did not change are preserved.
          state = State::Store.load(paths.state_file).success
          now = @clock.call

          # Phase 1: org expansion (sequential; per-org failures isolated).
          # see disagreement #7. CF3 (Slice 4 Lane 02) passes the
          # prev state's org map so an org-list `Failure` can
          # preserve the prior good `repo_count` + `last_listed_at`
          # instead of clobbering with `0`/`nil`.
          org_records, discovered_repos = expand_orgs(config, now, prev_orgs: state.orgs)

          # Phase 2: dedupe explicit + discovered repos by (host, owner,
          # name); explicit wins.
          repos_to_process = dedupe(config.repos, discovered_repos)

          # Phase 3: fan out per-repo work through barrier + semaphore.
          # Results are gathered in a mutex-protected array (barrier
          # tasks run on a Fiber scheduler; shared mutation must be
          # serialized). Each result is a [key, Repo | nil, error] tuple
          # (see process_one for the shape).
          results_mutex = Mutex.new
          results = []

          repos_to_process.each do |repo_ref|
            barrier.async do
              # `semaphore.async` spawns a child task and returns its
              # Task handle. The barrier only tracks this outer task;
              # if we don't `.wait` on the inner task, `barrier.wait`
              # would return before the per-repo work finishes and
              # `build_new_state` would see an empty results array.
              inner = semaphore.async do
                outcome = process_one(repo_ref, config, now)
                results_mutex.synchronize { results << outcome }
              end
              inner.wait
            end
          end
          barrier.wait

          # Phase 4: assemble new state, write once.
          new_state = build_new_state(state, results, org_records)
          write_result = State::Store.write(paths.state_file, new_state)
          return write_result if write_result.failure?

          Dry::Monads::Success(new_state)
        end
      end

      private

      # Expands each OrgRef into RepoRefs via the injected forge. On
      # list_org Failure, the org is recorded with the prior good
      # `repo_count` + `last_listed_at` preserved (looked up from
      # `prev_orgs`) and a non-nil `last_error` set to the
      # failure's reason — CF3 (Slice 4 Lane 02). On the first-ever
      # run for an org, `prev_orgs[key]` is nil and we fall back to
      # `last_listed_at: nil, repo_count: 0, last_error: <reason>`.
      def expand_orgs(config, now, prev_orgs: {})
        org_records = {}
        discovered = []
        config.orgs.each do |org_ref|
          result = @forge.list_org(org_ref)
          key = org_key(org_ref)
          if result.success?
            org_records[key] = State::Store::Org.new(
              last_listed_at: now,
              repo_count: result.success.length
            )
            discovered.concat(result.success)
          else
            prev = prev_orgs[key]
            org_records[key] = State::Store::Org.new(
              last_listed_at: prev&.last_listed_at,
              repo_count: prev&.repo_count || 0,
              last_error: format_org_failure(result.failure)
            )
          end
        end
        [org_records, discovered]
      end

      def org_key(o) = "#{o.host}/#{o.name}"

      def format_org_failure(failure)
        return "list failed" if failure.nil?
        return failure[:reason] if failure.is_a?(Hash) && failure[:reason]
        failure.inspect
      end

      def repo_key(r) = "#{r.host}/#{r.owner}/#{r.name}"

      # First-write-wins dedupe keyed by (host, owner, name).
      def dedupe(explicit, discovered)
        seen = {}
        explicit.each { |r| seen[repo_key(r)] ||= r }
        discovered.each { |r| seen[repo_key(r)] ||= r }
        seen.values
      end

      # Process a single repo: plan + execute. Returns
      #   [key, Repo]                                  on success
      #   [key, nil, error_string]                     on action Failure
      #   [key, nil, "unhandled: ..."]                 on unexpected raise
      # The last-resort rescue is the engine's G8 guarantee: nothing
      # in process_one propagates an exception out of the semaphore.
      def process_one(repo_ref, config, now)
        key = repo_key(repo_ref)
        path = File.join(config.base_dir, repo_ref.host, repo_ref.owner, repo_ref.name)

        plan_result = RepoPlan.call(
          repo_ref: repo_ref,
          path: path,
          scm: @scm,
          refresh_interval: config.refresh_interval,
          now: now
        )
        if plan_result.failure?
          return [key, nil, "plan call failed: #{plan_result.failure.inspect}"]
        end
        plan = plan_result.success

        # The plan's default_branch is implicit in the decision but
        # not exposed in the Plan object. The engine re-probes
        # default_branch for the state record. We MUST NOT call
        # scm.default_branch(path) before the clone — `chdir:` to a
        # non-existent path raises ENOENT in `Kernel#spawn`, which is
        # not a clean Failure (it's an exception, not a non-zero
        # exit). So default_branch is initialized to nil and only
        # populated after the path exists.
        default_branch = nil

        final_status = plan.status
        last_error = nil

        case plan.action
        when :clone
          result = @scm.clone(@url_builder.call(repo_ref), path)
          if result.failure?
            final_status = "error"
            last_error = "clone failed: #{result.failure.inspect}"
          else
            # The clone succeeded; the repo is now "clean" (a fresh
            # clone has no local changes). Re-probe default_branch on
            # the now-cloned path.
            final_status = "clean"
            default_branch = @scm.default_branch(path).value_or { nil }
          end
        when :fast_forward
          default_branch = @scm.default_branch(path).value_or { nil }
          if default_branch.nil?
            final_status = "error"
            last_error = "default_branch probe failed; cannot fast-forward"
          else
            result = @scm.fast_forward(path, default_branch)
            if result.failure?
              failure = result.failure
              if failure.is_a?(Hash) && failure[:reason].to_s.include?("diverged")
                # G4: divergence is not an error — it's a state.
                final_status = "diverged"
                last_error = failure[:reason].to_s
              else
                final_status = "error"
                last_error = failure.inspect
              end
            end
          end
        when :switch
          default_branch = @scm.default_branch(path).value_or { nil }
          if default_branch.nil?
            final_status = "error"
            last_error = "default_branch probe failed; cannot switch"
          else
            # The plan only returns :switch for a clean tree (gate G5;
            # disagreement #1), so this scm.switch is on a clean tree.
            # git switch refuses on dirty by default per its man page;
            # if it ever refused here, that means the plan's guard was
            # bypassed — capture the error.
            result = @scm.switch(path, default_branch)
            if result.failure?
              final_status = "error"
              last_error = result.failure.inspect
            else
              # The switch succeeded; the repo is now on the default
              # branch with a clean tree.
              final_status = "clean"
            end
          end
        when :skip_fresh, :up_to_date
          # No SCM side effect. State is already "clean". Probe
          # default_branch for the state record (cheap — cached on
          # first call).
          default_branch = @scm.default_branch(path).value_or { nil }
        when :report_dirty, :report_diverged, :report_wrong_branch,
          :report_detached
          # The plan already classified the status; these are
          # *observations* about the repo, not error conditions.
          # last_error stays nil so the state row reads cleanly.
          # Probe default_branch for the state record.
          default_branch = @scm.default_branch(path).value_or { nil }
        when :report_error
          # The plan classified a probe failure; the diagnostic goes
          # into last_error. Don't re-probe default_branch — the path
          # may not exist or the probe may still fail.
          last_error = plan.reason
        end

        last_fetch = @scm.last_fetch_at(path).value_or { nil }
        repo = State::Store::Repo.new(
          default_branch: default_branch,
          last_fetch_at: last_fetch,
          last_synced_at: now,
          status: final_status,
          last_error: last_error
        )
        [key, repo]
      rescue => e
        # Last-resort: any unexpected exception (e.g. Shell.run raising
        # outside an ambient task) is captured so the engine's barrier
        # completes and state is written.
        [key, nil, "unhandled: #{e.class}: #{e.message}"]
      end

      # Assembles the new State from the in-memory prev state + the
      # run's per-repo outcomes + the org records. Failures get a
      # status: error row so every processed repo has a state entry
      # (gate G8).
      def build_new_state(prev, results, org_records)
        repos = prev.repos.dup
        results.each do |key, repo, error|
          repos[key] = (repo || State::Store::Repo.new(
            default_branch: nil,
            last_fetch_at: nil,
            last_synced_at: nil,
            status: "error",
            last_error: error
          ))
        end
        orgs = prev.orgs.merge(org_records)
        State::Store::State.new(repos: repos, orgs: orgs)
      end
    end
  end
end
