# frozen_string_literal: true

require_relative "../test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "space/server/jobs/consumer"
require "space/server/runs/stream_key"

class ConsumerTest < Minitest::Test
  REDIS_SKIP_MSG = "Redis unreachable".freeze
  FIXTURE_DIR = File.join(__dir__, "..", "fixtures", "claude_stream_json")
  BASIC   = File.readlines(File.join(FIXTURE_DIR, "basic.jsonl"), chomp: true).freeze
  PARTIAL = File.readlines(File.join(FIXTURE_DIR, "partial.jsonl"), chomp: true).freeze

  def redis_endpoint
    url = ENV["REDIS_URL"]
    url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
  end

  def redis_reachable?
    Sync do
      client = Async::Redis::Client.new(redis_endpoint)
      client.call("PING")
      client.close
      true
    rescue
      false
    end
  end

  def setup
    skip REDIS_SKIP_MSG unless redis_reachable?
    conn = Space::Server::App["db.gateway"].connection
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :jobs, :runs, :users].each { |t| conn[t].delete }
    @user               = Factory[:user]
    @jobs_repo          = Space::Server::App["repos.jobs_repo"]
    @runs_repo          = Space::Server::App["repos.runs_repo"]
    @conversations_repo = Space::Server::App["repos.conversations_repo"]
    @messages_repo      = Space::Server::App["repos.messages_repo"]
  end

  def with_redis
    Sync do
      client = Async::Redis::Client.new(redis_endpoint)
      begin
        yield client
      ensure
        client.close
      end
    end
  end

  def consumer(redis)
    Space::Server::Jobs::Consumer.new(
      redis: redis, jobs_repo: @jobs_repo, runs_repo: @runs_repo,
      conversations_repo: @conversations_repo, messages_repo: @messages_repo
    )
  end

  def seed_raw(redis, job, lines, exit_code: 0)
    key = "job:#{job.id}:raw"
    redis.del(key)
    lines.each { |line| redis.xadd(key, "*", "type", "out", "data", line) }
    redis.xadd(key, "*", "type", "exit", "data", JSON.generate(code: exit_code)) if exit_code
    key
  end

  def display_types(redis, run_id)
    redis.xrange(Space::Server::Runs::StreamKey.for(run_id), "-", "+").map { |e| e[1][1] }
  end

  def drained_run(job_id)
    job = @jobs_repo.by_pk(job_id)
    refute_nil job.run_id, "drain must link a run to the job"
    [job, @runs_repo.by_pk(job.run_id)]
  end

  def test_drains_basic_fixture_into_conversation_and_display_events
    job = Factory[:job, user_id: @user.id, status: "running"]
    with_redis do |redis|
      key = seed_raw(redis, job, BASIC)
      redis.xadd(key, "*", "type", "err", "data", "stderr noise: not transcript")

      consumer(redis).drain(job)

      job, run = drained_run(job.id)
      assert run.complete?, "expected complete run, got #{run.status}"
      assert_equal "running", job.status, "consumer must never write jobs.status"

      conv = @conversations_repo.by_pk(run.conversation_id)
      refute_nil conv
      assert_equal "job", conv.source
      assert_equal @user.id, conv.user_id

      msgs = @messages_repo.for_conversation(run.conversation_id)
      assert_equal 2, msgs.length, "basic fixture has two assistant envelopes"
      assert msgs.all? { |m| m.role == "assistant" }
      assert msgs.any? { |m| m.blocks.any? { |b| b["type"] == "text" && b["text"] == "ok" } }
      assert msgs.any? { |m| m.blocks.any? { |b| b["type"] == "thinking" } }
      refute msgs.any? { |m| m.blocks.any? { |b| b.to_s.include?("stderr noise") } }

      types = display_types(redis, run.id)
      assert_includes types, "run_init"
      assert_includes types, "message_start"
      assert_equal "run_complete", types.last
    end
  end

  def test_drains_partial_fixture_into_single_message
    job = Factory[:job, user_id: @user.id, status: "running"]
    with_redis do |redis|
      seed_raw(redis, job, PARTIAL)

      consumer(redis).drain(job)

      _, run = drained_run(job.id)
      assert run.complete?

      msgs = @messages_repo.for_conversation(run.conversation_id)
      assert_equal 1, msgs.length, "partial mode must not double-persist the interleaved assistant envelopes"
      blocks = msgs.first.blocks
      assert_equal %w[thinking text], blocks.map { |b| b["type"] }
      assert_equal "ok", blocks.last["text"]

      assert_equal "run_complete", display_types(redis, run.id).last
    end
  end

  def test_nonzero_exit_finishes_run_failed
    job = Factory[:job, user_id: @user.id, status: "failed"]
    with_redis do |redis|
      seed_raw(redis, job, BASIC, exit_code: 3)

      consumer(redis).drain(job)

      _, run = drained_run(job.id)
      assert run.failed?, "nonzero exit must fail the run"
      refute_nil run.conversation_id, "conversation stays linked even on failure"
    end
  end

  def test_redrain_leaves_one_conversation_and_no_duplicated_messages
    job = Factory[:job, user_id: @user.id, status: "succeeded"]
    with_redis do |redis|
      seed_raw(redis, job, BASIC)

      consumer(redis).drain(job)
      _, run = drained_run(job.id)
      first_conversation_id = run.conversation_id
      first_count = @messages_repo.for_conversation(first_conversation_id).length

      consumer(redis).drain(@jobs_repo.by_pk(job.id))
      _, run = drained_run(job.id)

      refute_nil run.conversation_id
      refute_equal first_conversation_id, run.conversation_id, "re-drain replaces with a fresh conversation"
      assert_equal first_count, @messages_repo.for_conversation(run.conversation_id).length,
        "messages visible through the run must not be duplicated"
    end
  end

  def test_poll_drains_discovered_jobs_then_skips_them
    job = Factory[:job, user_id: @user.id, status: "running"]
    Factory[:job, user_id: @user.id, status: "queued"]
    with_redis do |redis|
      seed_raw(redis, job, PARTIAL)

      c = consumer(redis)
      tasks = c.poll
      assert_equal 1, tasks.length, "only the running job is drainable"
      tasks.each(&:wait)

      _, run = drained_run(job.id)
      assert run.complete?

      assert_empty c.poll, "a drained job (terminal run) must not be re-discovered"
    end
  end

  def test_drainable_jobs_excludes_queued_canceled_and_drained
    running  = Factory[:job, user_id: @user.id, status: "running"]
    stranded = Factory[:job, user_id: @user.id, status: "failed"]
    Factory[:job, user_id: @user.id, status: "queued"]
    Factory[:job, user_id: @user.id, status: "canceled"]
    drained = Factory[:job, user_id: @user.id, status: "succeeded"]
    run = @runs_repo.create(user_id: @user.id, status: 2, published: false, created_at: Time.now, updated_at: Time.now)
    @jobs_repo.update(drained.id, run_id: run.id)

    with_redis do |redis|
      ids = consumer(redis).drainable_jobs.map(&:id).sort
      assert_equal [running.id, stranded.id].sort, ids
    end
  end

  def test_terminal_job_with_missing_exit_frame_fails_run
    job = Factory[:job, user_id: @user.id, status: "succeeded"]
    with_redis do |redis|
      seed_raw(redis, job, BASIC.first(3), exit_code: nil)

      consumer(redis).drain(job)

      _, run = drained_run(job.id)
      assert run.failed?, "a quiet stream from a finished producer must fail the run, not hang"
    end
  end
end
