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
end
