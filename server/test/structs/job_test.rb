# frozen_string_literal: true

require_relative "../test_helper"

class JobStructTest < Minitest::Test
  def setup
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    [:artifacts, :iterations, :annotations, :conversation_shares, :messages, :conversations, :jobs, :runs, :spaces, :users].each { |t| conn[t].delete }

    @repo  = Space::Server::App["repos.jobs_repo"]
    @owner = Factory[:user]
    @stranger = Factory[:user]
  end

  def make_job(status: "queued")
    @repo.by_pk(Factory[:job, user_id: @owner.id, status: status].id)
  end

  def test_status_predicates
    %w[queued running succeeded failed canceled].each do |status|
      job = make_job(status: status)
      %w[queued running succeeded failed canceled].each do |candidate|
        result = job.public_send("#{candidate}?")
        if candidate == status
          assert result, "status #{status} must be #{candidate}?"
        else
          refute result, "status #{status} must not be #{candidate}?"
        end
      end
    end
  end

  def test_owned_by
    job = make_job
    assert job.owned_by?(@owner), "owner must own the job"
    refute job.owned_by?(@stranger), "stranger must not own the job"
    refute job.owned_by?(nil), "nil must not own any job"
  end
end
