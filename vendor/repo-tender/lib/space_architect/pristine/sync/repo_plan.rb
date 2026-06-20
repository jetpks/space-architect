# frozen_string_literal: true

require "time"
require "dry/monads"
require "space_architect/pristine/scm/client"
require "space_architect/pristine/scm/status"

module SpaceArchitect::Pristine
  module Sync
    # Pure-ish evergreen evaluation. Given a RepoRef + on-disk path +
    # SCM client + refresh_interval, observe the repo and decide an
    # action. Returns a Plan (Data) carrying {action, status, reason}.
    #
    # Per Slice 2 PRD §3.3 + gate G2 seam, the plan is the *decision*
    # half; the engine is the *execution* half. The plan only uses
    # read-side SCM methods (`status`, `current_branch`,
    # `default_branch`, `last_fetch_at`) plus `fetch` when not-fresh
    # (a network observation). It never mutates branches.
    #
    # Action ↔ status mapping (per Slice 2 gates):
    #
    #   :clone               → status "missing" (before action) / "clean" (after)
    #   :fast_forward        → status "clean" (after)
    #   :switch              → status "clean" (after; the source status was wrong_branch/detached)
    #   :skip_fresh          → status "clean"
    #   :up_to_date          → status "clean"
    #   :sync_empty          → status "clean" (empty clone of empty/unborn remote)
    #   :report_dirty        → status "dirty"
    #   :report_diverged     → status "diverged"
    #   :report_wrong_branch → status "wrong_branch"
    #   :report_detached     → status "detached"
    #   :report_error        → status "error" (probe Failure translation; not in the spec's
    #                                            nine actions but required by G8)
    #
    # The plan always returns Success(Plan). Any SCM-probe Failure is
    # translated to a :report_error action so the engine has a uniform
    # dispatch surface. The plan never raises.
    module RepoPlan
      extend Dry::Monads[:result]

      Plan = Data.define(:action, :status, :reason) do
        def initialize(action:, status:, reason: nil)
          super
        end
      end

      def self.call(repo_ref:, path:, scm:, refresh_interval:, now: Time.now)
        # 1. Present? (PRD §3.3 step 1; gate G6)
        unless Dir.exist?(path)
          return Success(Plan.new(
            action: :clone,
            status: "missing",
            reason: "path does not exist: #{path}"
          ))
        end

        # 2. Working-tree status (porcelain v2 with branch.ab).
        #    This single call gives us clean/dirty + the ahead/behind
        #    numbers we need for the behind check (disagreement #2:
        #    we use SCM::Status#behind / #ahead, not a new SCM
        #    boundary, since the BOUNDARIES list only permits adding
        #    `switch` to SCM::Client).
        status_result = scm.status(path)
        if status_result.failure?
          return report_error(repo_ref, "status probe failed: #{status_result.failure.inspect}")
        end
        scm_status = status_result.success

        # 2b. Unborn (empty) repo? No commits exist anywhere on the
        #     local clone. Skip the `current_branch` / `default_branch`
        #     probes — both would succeed but `default_branch` calls
        #     `git remote set-head origin -a` which exits non-zero on an
        #     empty remote ("Cannot determine remote HEAD"), turning a
        #     valid empty clone into a false :report_error. Delegate the
        #     remote-has-commits? check to the engine's sync_empty call.
        if scm_status.unborn?
          if scm_status.clean?
            return Success(Plan.new(
              action: :sync_empty,
              status: "clean",
              reason: "empty repository (no commits yet)"
            ))
          else
            return Success(Plan.new(
              action: :report_dirty,
              status: "dirty",
              reason: "empty repository with uncommitted local files; not touching"
            ))
          end
        end

        # 3. Current branch + default branch.
        current_result = scm.current_branch(path)
        if current_result.failure?
          return report_error(repo_ref, "current_branch probe failed: #{current_result.failure.inspect}")
        end
        current = current_result.success

        default_result = scm.default_branch(path)
        if default_result.failure?
          return report_error(repo_ref, "default_branch probe failed: #{default_result.failure.inspect}")
        end
        default_branch = default_result.success

        # 4. Detached or wrong branch? (gate G5)
        if current.nil?
          if scm_status.clean?
            return Success(Plan.new(
              action: :switch,
              status: "detached",
              reason: "detached HEAD on a clean tree; switching to #{default_branch}"
            ))
          else
            return Success(Plan.new(
              action: :report_detached,
              status: "detached",
              reason: "detached HEAD with a dirty tree; not switching"
            ))
          end
        elsif current != default_branch
          if scm_status.clean?
            return Success(Plan.new(
              action: :switch,
              status: "wrong_branch",
              reason: "on branch #{current} (default is #{default_branch}); switching"
            ))
          else
            return Success(Plan.new(
              action: :report_wrong_branch,
              status: "wrong_branch",
              reason: "on branch #{current} (default is #{default_branch}) with a dirty tree; not switching"
            ))
          end
        end

        # 5. Clean? (gate G3 — dirty repos are NEVER touched)
        unless scm_status.clean?
          return Success(Plan.new(
            action: :report_dirty,
            status: "dirty",
            reason: "working tree has changes (#{scm_status.entries.length} entry/entries)"
          ))
        end

        # 6. Fresh? (PRD §3.3 step 4; gate G2; PHASE-0 ruling: nil /
        #    stale / Failure all → stale; never skip on unreadable/
        #    absent FETCH_HEAD)
        last_fetch = scm.last_fetch_at(path)
        if last_fetch.success?
          t = last_fetch.success
          if t && (now - t) <= refresh_interval
            return Success(Plan.new(
              action: :skip_fresh,
              status: "clean",
              reason: "fetched at #{t.iso8601} within refresh_interval=#{refresh_interval}s"
            ))
          end
        end

        # 7. Not fresh → fetch + re-check status for behind / diverged /
        #    up_to_date. After fetch, `origin/<default>` is up to date
        #    with the remote, so the next `scm.status` call's
        #    `behind`/`ahead` (porcelain v2 `# branch.ab`) are current.
        fetch_result = scm.fetch(path)
        if fetch_result.failure?
          return report_error(repo_ref, "fetch failed: #{fetch_result.failure.inspect}")
        end

        re_status = scm.status(path)
        if re_status.failure?
          return report_error(repo_ref, "status re-probe after fetch failed: #{re_status.failure.inspect}")
        end
        behind = re_status.success.behind
        ahead = re_status.success.ahead

        # 8. Diverged? (gate G4 — never reset, never auto-resolve)
        if ahead > 0
          return Success(Plan.new(
            action: :report_diverged,
            status: "diverged",
            reason: "local is #{ahead} commit(s) ahead of origin/#{default_branch} (no reset --hard)"
          ))
        end

        # 9. Behind? (gate G1)
        if behind > 0
          return Success(Plan.new(
            action: :fast_forward,
            status: "clean",
            reason: "behind by #{behind} commit(s); merging --ff-only"
          ))
        end

        # 10. Up to date (no-op — just a state write at the engine layer)
        Success(Plan.new(
          action: :up_to_date,
          status: "clean",
          reason: "up to date with origin/#{default_branch}"
        ))
      end

      def self.report_error(repo_ref, reason)
        Success(Plan.new(
          action: :report_error,
          status: "error",
          reason: "#{repo_key(repo_ref)}: #{reason}"
        ))
      end

      def self.repo_key(r)
        "#{r.host}/#{r.owner}/#{r.name}"
      end
    end
  end
end
