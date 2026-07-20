# frozen_string_literal: true

module Space
  module Server
    module Repos
      class JobsRepo < Space::Server::DB::Repo
        def by_pk(id)
          jobs.by_pk(id).one
        end

        def create(attrs)
          jobs.command(:create).call(attrs)
        end

        def update(id, attrs)
          jobs.by_pk(id).command(:update).call(attrs)
        end

        def delete(id)
          jobs.by_pk(id).command(:delete).call
        end

        def by_user(user_id)
          jobs.where(user_id: user_id).to_a
        end

        # The job that produced a run, if any (runs made via ingest have none).
        def by_run_id(run_id)
          jobs.where(run_id: run_id).to_a.first
        end

        # Index scope: a user's own jobs, newest first, capped at 100 (I10 — no
        # pagination yet).
        def list_for_user(user_id, limit: 100)
          jobs.where(user_id: user_id).order(Sequel.desc(:created_at)).limit(limit).to_a
        end

        LEASE_SECONDS = 60
        MAX_ATTEMPTS  = 3

        # Atomically claim the oldest queued job: queued → running, lease set,
        # attempts incremented — one UPDATE whose MATERIALIZED CTE locks the
        # chosen row (FOR UPDATE) exactly once while concurrent claimers SKIP
        # LOCKED rows, so two claimers can never receive the same job. The CTE
        # must be MATERIALIZED: a bare IN-subquery may be re-evaluated per
        # outer row (EvalPlanQual follows the self-updated tuple), claiming a
        # second row in the same statement. Returns the job or nil.
        def claim(lease_seconds: LEASE_SECONDS)
          now = Time.now
          oldest_queued = jobs.dataset
            .where(status: "queued")
            .order(:created_at, :id)
            .limit(1)
            .select(:id)
            .for_update
            .skip_locked
          claimed = jobs.dataset
            .with(:candidate, oldest_queued, materialized: true)
            .where(id: jobs.dataset.db[:candidate].select(:id))
            .returning(:id)
            .update(
              status:       "running",
              leased_until: now + lease_seconds,
              attempts:     Sequel[:attempts] + 1,
              updated_at:   now
            )
          claimed.empty? ? nil : by_pk(claimed.first[:id])
        end

        # Extend a running job's lease.
        def heartbeat(id, lease_seconds: LEASE_SECONDS)
          now = Time.now
          jobs.dataset.where(id: id, status: "running")
              .update(leased_until: now + lease_seconds, updated_at: now)
        end

        # Requeue running jobs whose lease expired (crash recovery); jobs that
        # already burned max_attempts claims are failed instead of requeued.
        def sweep_stale(max_attempts: MAX_ATTEMPTS)
          now = Time.now
          stale = jobs.dataset.where(status: "running").where { leased_until < now }
          requeued = stale.where { attempts < max_attempts }
                          .update(status: "queued", leased_until: nil, updated_at: now)
          failed = stale.where { attempts >= max_attempts }
                        .update(status: "failed", leased_until: nil, updated_at: now)
          { requeued: requeued, failed: failed }
        end

        def mark_succeeded(id) = finish(id, "succeeded")
        def mark_failed(id)    = finish(id, "failed")

        CANCELABLE_STATUSES = %w[queued running].freeze

        # Atomically cancel a queued or running job: one guarded UPDATE per
        # candidate prior status (each individually atomic, and mutually
        # exclusive since a row holds exactly one status at a time), so a job
        # already terminal — or one a concurrent claim/finish just moved out
        # from under us — is left untouched. Returns the prior status
        # ("queued" or "running") the job held when the transition landed, or
        # nil for a no-op (already terminal, or unknown id).
        def cancel(id)
          now = Time.now
          CANCELABLE_STATUSES.find do |prior_status|
            jobs.dataset.where(id: id, status: prior_status)
                .update(status: "canceled", leased_until: nil, updated_at: now) == 1
          end
        end

        private

        # WHERE status='running' guards against resurrecting a job a
        # concurrent #cancel already moved to "canceled" — the executor's own
        # heartbeat-driven cancellation detection is a latency optimization,
        # this guard is the correctness backstop.
        def finish(id, status)
          jobs.dataset.where(id: id, status: "running")
              .update(status: status, leased_until: nil, updated_at: Time.now)
        end
      end
    end
  end
end
