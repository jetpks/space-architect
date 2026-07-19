# frozen_string_literal: true

require_relative "../test_helper"

class JobsRepoTest < Minitest::Test
  def conn
    @conn ||= Space::Server::App["db.gateway"].connection
  end

  def setup
    Faker::Internet.unique.clear
    [:artifacts, :iterations, :annotations, :conversation_shares, :messages, :conversations, :jobs, :runs, :spaces, :users].each { |t| conn[t].delete }
  end

  def jobs_repo = Space::Server::Repos::JobsRepo.new

  def make_user(overrides = {})
    Factory[:user, **overrides]
  end

  def test_crud_round_trip
    user = make_user
    job = Factory[:job, user_id: user.id]
    assert_kind_of Integer, job.id
    assert_equal "queued", jobs_repo.by_pk(job.id).status

    jobs_repo.update(job.id, status: "running")
    assert_equal "running", jobs_repo.by_pk(job.id).status

    jobs_repo.delete(job.id)
    assert_nil jobs_repo.by_pk(job.id)
  end

  def test_spec_jsonb_round_trips
    user = make_user
    spec = {
      "harness" => { "type" => "claude", "model" => "sonnet", "backend" => { "base_url" => "https://api.example.com" } },
      "prompt" => "hello",
      "environment" => { "env" => { "FOO" => "bar" }, "secrets" => [{ "ref" => "op://x", "name" => "Y" }], "deps" => ["git"] }
    }
    job = Factory[:job, user_id: user.id, spec: spec]
    found = jobs_repo.by_pk(job.id)
    assert_equal spec, found.spec
  end

  def test_by_user_finder
    u1 = make_user
    u2 = make_user
    j1 = Factory[:job, user_id: u1.id]
    j2 = Factory[:job, user_id: u2.id]
    ids = jobs_repo.by_user(u1.id).map(&:id)
    assert_includes ids, j1.id
    refute_includes ids, j2.id
  end

  def test_status_check_constraint_rejects_invalid_status
    user = make_user
    err = assert_raises(ROM::SQL::CheckConstraintError) do
      Factory[:job, user_id: user.id, status: "bogus"]
    end
    assert_match(/jobs_status_check/, err.message)
  end

  # --- claim / lease / sweep (I07 executor lane) ---

  def test_claim_takes_oldest_queued_job_sets_lease_and_increments_attempts
    user  = make_user
    older = Factory[:job, user_id: user.id, created_at: Time.now - 60, updated_at: Time.now - 60]
    newer = Factory[:job, user_id: user.id]

    claimed = jobs_repo.claim(lease_seconds: 30)
    assert_equal older.id, claimed.id
    assert_equal "running", claimed.status
    assert_equal 1, claimed.attempts
    refute_nil claimed.leased_until
    assert claimed.leased_until > Time.now, "lease must extend into the future"

    second = jobs_repo.claim
    assert_equal newer.id, second.id
    refute_equal claimed.id, second.id
  end

  def test_claim_returns_nil_when_nothing_queued
    assert_nil jobs_repo.claim

    user = make_user
    Factory[:job, user_id: user.id, status: "succeeded"]
    assert_nil jobs_repo.claim
  end

  def test_claim_increments_attempts_across_requeues
    user = make_user
    job  = Factory[:job, user_id: user.id, attempts: 1]
    claimed = jobs_repo.claim
    assert_equal job.id, claimed.id
    assert_equal 2, claimed.attempts
  end

  def test_heartbeat_extends_lease_of_running_job_only
    user = make_user
    Factory[:job, user_id: user.id]
    claimed = jobs_repo.claim(lease_seconds: 1)

    jobs_repo.heartbeat(claimed.id, lease_seconds: 300)
    assert jobs_repo.by_pk(claimed.id).leased_until > claimed.leased_until

    jobs_repo.mark_failed(claimed.id)
    jobs_repo.heartbeat(claimed.id, lease_seconds: 300)
    assert_nil jobs_repo.by_pk(claimed.id).leased_until, "heartbeat must not resurrect a terminal job"
  end

  def test_sweep_requeues_expired_lease_below_max_attempts
    user = make_user
    job  = Factory[:job, user_id: user.id, status: "running", leased_until: Time.now - 5, attempts: 1]

    result = jobs_repo.sweep_stale(max_attempts: 3)
    assert_equal({ requeued: 1, failed: 0 }, result)

    swept = jobs_repo.by_pk(job.id)
    assert_equal "queued", swept.status
    assert_nil swept.leased_until
  end

  def test_sweep_fails_expired_lease_at_max_attempts
    user = make_user
    job  = Factory[:job, user_id: user.id, status: "running", leased_until: Time.now - 5, attempts: 3]

    result = jobs_repo.sweep_stale(max_attempts: 3)
    assert_equal({ requeued: 0, failed: 1 }, result)
    assert_equal "failed", jobs_repo.by_pk(job.id).status
  end

  def test_sweep_ignores_live_leases_and_non_running_jobs
    user = make_user
    live   = Factory[:job, user_id: user.id, status: "running", leased_until: Time.now + 60, attempts: 1]
    queued = Factory[:job, user_id: user.id]

    result = jobs_repo.sweep_stale
    assert_equal({ requeued: 0, failed: 0 }, result)
    assert_equal "running", jobs_repo.by_pk(live.id).status
    assert_equal "queued", jobs_repo.by_pk(queued.id).status
  end

  def test_terminal_transitions_set_status_and_clear_lease
    user = make_user
    Factory[:job, user_id: user.id]
    Factory[:job, user_id: user.id]

    first  = jobs_repo.claim
    second = jobs_repo.claim

    jobs_repo.mark_succeeded(first.id)
    jobs_repo.mark_failed(second.id)

    succeeded = jobs_repo.by_pk(first.id)
    failed    = jobs_repo.by_pk(second.id)
    assert_equal "succeeded", succeeded.status
    assert_nil succeeded.leased_until
    assert_equal "failed", failed.status
    assert_nil failed.leased_until
  end
end
