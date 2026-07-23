# frozen_string_literal: true

require_relative "../test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "stringio"
require "dry/monads"
require "space/server/jobs/executor"

class ExecutorTest < Minitest::Test
  include Dry::Monads[:result]

  REDIS_SKIP_MSG = "Redis unreachable".freeze

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

  def conn = @conn ||= Space::Server::App["db.gateway"].connection

  def setup
    skip REDIS_SKIP_MSG unless redis_reachable?
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:artifacts, :iterations, :annotations, :conversation_shares, :messages, :conversations, :jobs, :runs, :spaces, :users].each { |t| conn[t].delete }
    @user = Factory[:user]
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

  def jobs_repo = Space::Server::Repos::JobsRepo.new
  def runs_repo = Space::Server::Repos::RunsRepo.new

  # --- fakes (the executor's designed injection seams) ---

  class FakeSpawner
    attr_reader :argvs, :envs, :cidfiles

    def initialize(*handles)
      @handles  = handles
      @argvs    = []
      @envs     = []
      @cidfiles = []
    end

    def calls = @argvs.length

    def call(argv, env:, cidfile: nil)
      @argvs << argv
      @envs << env
      @cidfiles << cidfile
      @handles.shift
    end
  end

  class FakeHandle
    attr_reader :stdout, :stderr, :stops, :kills

    def initialize(stdout: "", stderr: "", code: 0, hang: false)
      @stdout = StringIO.new(stdout)
      @stderr = StringIO.new(stderr)
      @code   = code
      @hang   = hang
      @stops  = 0
      @kills  = 0
    end

    # Hanging handles ignore stop (like a child ignoring TERM) and exit 137 on kill.
    def wait
      sleep(0.005) while @hang && @kills.zero?
      @kills.zero? ? @code : 137
    end

    def stop = @stops += 1
    def kill = @kills += 1
  end

  class RecordingRedis
    attr_reader :xadds

    def initialize(client)
      @client = client
      @xadds  = []
    end

    def xadd(*args)
      @xadds << args
      @client.xadd(*args)
    end

    def expire(*args) = @client.expire(*args)
  end

  DEFAULT_SPEC = {
    "harness" => { "type" => "claude", "model" => "sonnet-5", "backend" => { "base_url" => "https://api.example.com" } },
    "prompt" => "do the thing",
    "environment" => {
      "env" => { "FOO" => "bar" },
      "secrets" => [{ "ref" => "op://vault/item/field", "name" => "API_KEY" }],
      "deps" => [],
      "permissions" => { "network" => false, "mounts" => [] }
    }
  }.freeze

  def make_job(spec_overrides = {})
    Factory[:job, user_id: @user.id, spec: DEFAULT_SPEC.merge(spec_overrides)]
  end

  def key_for(job) = "job:#{job.id}:raw"

  def build_executor(redis:, spawner:, env_image: nil, secrets: { "API_KEY" => "sekret-value" }, resolver: nil, **opts)
    Space::Server::Jobs::Executor.new(
      jobs_repo: jobs_repo,
      runs_repo: runs_repo,
      redis: redis,
      env_image: env_image || ->(_environment) { Success("img:abc123") },
      secret_resolver: resolver || ->(_refs) { secrets },
      spawner: spawner,
      interval: 0.01,
      **opts
    )
  end

  # Resolver fake that echoes each ref name as a distinguishable value.
  def echo_resolver(seen = nil)
    ->(refs) { seen&.concat(refs); refs.to_h { |r| [r["name"], "resolved-#{r['name']}"] } }
  end

  def backend(**overrides)
    DEFAULT_SPEC["harness"].merge("backend" => { "base_url" => "https://api.example.com" }.merge(overrides))
  end

  # [type, data] pairs from the raw stream, in stream order.
  def events(redis, key)
    redis.xrange(key, "-", "+").map { |e| [e[1][1], e[1][3]] }
  end

  # --- tests ---

  def test_happy_path_runs_job_and_relays_output_onto_raw_stream
    job     = make_job
    spawner = FakeSpawner.new(FakeHandle.new(stdout: "line one\nline two\n", stderr: "warn: x\n", code: 0))

    with_redis do |redis|
      redis.del(key_for(job))
      claimed = build_executor(redis: redis, spawner: spawner).tick
      assert_equal job.id, claimed.id

      finished = jobs_repo.by_pk(job.id)
      assert_equal "succeeded", finished.status

      refute_nil finished.run_id
      run = runs_repo.by_pk(finished.run_id)
      assert_equal @user.id, run.user_id
      assert_equal "claude", run.harness
      assert_equal "sonnet-5", run.model
      assert_equal :pending, run.status

      evs = events(redis, key_for(job))
      assert_equal ["line one", "line two"], evs.select { |t, _| t == "out" }.map { |_, d| d }
      assert_includes evs, ["err", "warn: x"]
      assert_equal 1, evs.count { |t, _| t == "exit" }
      assert_equal "exit", evs.last[0], "exit must be the terminal event"
      assert_equal({ "code" => 0 }, JSON.parse(evs.last[1]))

      ttl = redis.ttl(key_for(job))
      assert ttl.positive? && ttl <= 1800, "TTL contract violated: #{ttl}"
    end
  end

  def test_xadd_matches_frozen_wire_contract_literally
    job     = make_job
    spawner = FakeSpawner.new(FakeHandle.new(stdout: "hello\n"))

    with_redis do |redis|
      redis.del(key_for(job))
      recorder = RecordingRedis.new(redis)
      build_executor(redis: recorder, spawner: spawner).tick

      assert_equal [key_for(job), "MAXLEN", "~", "10000", "*", "type", "out", "data", "hello"],
        recorder.xadds.first
      assert_equal [key_for(job), "MAXLEN", "~", "10000", "*", "type", "exit", "data", %({"code":0})],
        recorder.xadds.last
    end
  end

  def test_nonzero_exit_fails_job_with_exit_event_and_no_retry
    job     = make_job
    spawner = FakeSpawner.new(FakeHandle.new(stdout: "boom\n", code: 3))

    with_redis do |redis|
      redis.del(key_for(job))
      build_executor(redis: redis, spawner: spawner).tick

      assert_equal "failed", jobs_repo.by_pk(job.id).status
      exits = events(redis, key_for(job)).select { |t, _| t == "exit" }
      assert_equal 1, exits.length
      assert_equal({ "code" => 3 }, JSON.parse(exits.first[1]))
      assert_nil jobs_repo.claim, "a failed execution must not be requeued"
    end
  end

  def test_env_build_failure_fails_job_without_spawning
    job     = make_job
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      redis.del(key_for(job))
      executor = build_executor(redis: redis, spawner: spawner,
        env_image: ->(_environment) { Failure("no such base image\napt exploded") })
      executor.tick

      assert_equal "failed", jobs_repo.by_pk(job.id).status
      assert_equal 0, spawner.calls, "env-build failure must not spawn the sandbox"

      evs = events(redis, key_for(job))
      assert_equal ["no such base image", "apt exploded"], evs.select { |t, _| t == "err" }.map { |_, d| d }
      assert_equal "exit", evs.last[0], "stream must still terminate for consumers"
    end
  end

  # --- durable failure evidence (I07 D2 / I11) ---

  def test_env_build_failure_persists_evidence_on_the_job_row
    job     = make_job
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      redis.del(key_for(job))
      executor = build_executor(redis: redis, spawner: spawner,
        env_image: ->(_environment) { Failure("no such base image\napt exploded") })
      executor.tick

      failed = jobs_repo.by_pk(job.id)
      assert_equal "failed", failed.status
      assert_equal "no such base image\napt exploded", failed.failure_evidence,
        "the build log must be readable from the job row, not just the raw stream"
    end
  end

  def test_env_build_failure_evidence_is_bounded_to_the_last_n_bytes
    job     = make_job
    spawner = FakeSpawner.new(FakeHandle.new)
    huge    = "x" * (Space::Server::Jobs::Executor::FAILURE_EVIDENCE_BYTES + 500)

    with_redis do |redis|
      redis.del(key_for(job))
      executor = build_executor(redis: redis, spawner: spawner, env_image: ->(_environment) { Failure(huge) })
      executor.tick

      stored = jobs_repo.by_pk(job.id).failure_evidence
      assert_equal Space::Server::Jobs::Executor::FAILURE_EVIDENCE_BYTES, stored.bytesize
      assert_equal huge[-10..], stored[-10..], "the tail (most recent output) must be kept, not the head"
    end
  end

  # --- kill-recovery bookkeeping (I09 D6) ---

  def test_reclaim_after_a_crash_supersedes_the_stranded_run_and_links_a_fresh_one
    job          = make_job
    conversation = Factory[:conversation, user_id: @user.id]
    spawner      = FakeSpawner.new(FakeHandle.new(stdout: "ok\n", code: 0))

    with_redis do |redis|
      redis.del(key_for(job))

      # Attempt 1: claim, create a run (mirrors Executor#create_run), link it.
      claimed = jobs_repo.claim
      run_a   = runs_repo.create(
        user_id: @user.id, harness: "claude", model: "sonnet-5", status: 0,
        conversation_id: conversation.id, created_at: Time.now, updated_at: Time.now
      )
      jobs_repo.update(claimed.id, run_id: run_a.id)

      # Simulate the crash: the lease goes stale and sweep_stale requeues the
      # job — run_a stays linked, stranded pending. This is the exact D6 shape.
      jobs_repo.heartbeat(claimed.id, lease_seconds: -1)
      jobs_repo.sweep_stale(max_attempts: 3)
      assert_equal "queued", jobs_repo.by_pk(claimed.id).status

      # Attempt 2: a normal claim + run picks the job back up.
      build_executor(redis: redis, spawner: spawner).tick

      finished = jobs_repo.by_pk(job.id)
      assert_equal "succeeded", finished.status, "the re-executed job must reach a terminal status"
      refute_equal run_a.id, finished.run_id, "the fresh attempt must link a new run"

      superseded = runs_repo.by_pk(run_a.id)
      assert superseded.failed?, "the stranded run must end terminal"
      assert_equal conversation.id, superseded.conversation_id, "forensics: the old run's conversation is preserved"

      # No run left over from the superseded attempt stays stranded pending/live;
      # the freshly linked run legitimately starts pending (the consumer, not the
      # executor, advances it — see test_happy_path_runs_job_and_relays_output_onto_raw_stream).
      other_runs = runs_repo.by_user(@user.id).reject { |r| r.id == finished.run_id }
      assert_equal [run_a.id], other_runs.map(&:id)
      refute_includes other_runs.map(&:status), :pending
      refute_includes other_runs.map(&:status), :live
    end
  end

  def test_secret_values_reach_child_env_but_never_argv
    make_job
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner).tick

      argv = spawner.argvs.first
      assert_equal({ "API_KEY" => "sekret-value" }, spawner.envs.first)
      assert argv.none? { |arg| arg.include?("sekret-value") }, "secret value leaked into argv"
      assert argv.none? { |arg| arg.start_with?("API_KEY=") }, "secret must be a bare -e NAME"
      assert_equal "-e", argv[argv.index("API_KEY") - 1]
      assert_equal "-e", argv[argv.index("FOO=bar") - 1]
    end
  end

  def test_sandbox_argv_shape
    make_job(
      "environment" => DEFAULT_SPEC["environment"].merge(
        "permissions" => { "network" => false, "mounts" => ["/data:/data:ro"] }
      )
    )
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner).tick

      argv = spawner.argvs.first
      assert_equal %w[container run --rm --cidfile], argv.first(4)
      assert_equal "none", argv[argv.index("--network") + 1]
      assert_equal "/data:/data:ro", argv[argv.index("-v") + 1]
      assert argv.index("img:abc123") < argv.index("claude"), "image tag must precede the harness command"
      assert_equal ["claude", "-p", "do the thing", "--model", "sonnet-5",
                    "--output-format", "stream-json", "--verbose"], argv.last(8)
    end
  end

  # --- backend wiring ---

  def test_backend_base_url_rides_argv_env_pair_into_the_child
    make_job
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner).tick

      argv = spawner.argvs.first
      pair = argv.index("ANTHROPIC_BASE_URL=https://api.example.com")
      refute_nil pair, "backend base_url must reach the child env"
      assert_equal "-e", argv[pair - 1]
    end
  end

  def test_api_key_ref_rides_name_only_argv_with_value_in_spawn_env_only
    make_job("harness" => backend("api_key_ref" => "op://vault/anthropic/key"))
    spawner = FakeSpawner.new(FakeHandle.new)
    seen    = []

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner, resolver: echo_resolver(seen)).tick

      assert_includes seen, { "name" => "ANTHROPIC_API_KEY", "ref" => "op://vault/anthropic/key" },
        "the ref must resolve through the existing secret machinery"
      assert_equal "resolved-ANTHROPIC_API_KEY", spawner.envs.first["ANTHROPIC_API_KEY"]

      argv = spawner.argvs.first
      assert_equal "-e", argv[argv.index("ANTHROPIC_API_KEY") - 1]
      assert argv.none? { |arg| arg.include?("resolved-ANTHROPIC_API_KEY") }, "api key value leaked into argv"
      assert argv.none? { |arg| arg.start_with?("ANTHROPIC_API_KEY=") }, "api key must be a bare -e NAME"
    end
  end

  def test_absent_api_key_ref_injects_no_key
    make_job
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner, resolver: echo_resolver).tick

      refute_includes spawner.envs.first.keys, "ANTHROPIC_API_KEY"
      argv = spawner.argvs.first
      refute_includes argv, "ANTHROPIC_API_KEY"
      assert argv.none? { |arg| arg.start_with?("ANTHROPIC_API_KEY=") }
    end
  end

  def test_harness_args_are_appended_to_harness_argv
    make_job("harness" => DEFAULT_SPEC["harness"].merge("args" => ["--max-turns", "3"]))
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner).tick

      argv = spawner.argvs.first
      assert argv.index("--model") > argv.index("claude"), "--model belongs to the harness argv"
      assert_equal ["--max-turns", "3"], argv.last(2)
    end
  end

  def test_backend_wins_environment_env_collision
    make_job(
      "harness" => backend("api_key_ref" => "op://vault/anthropic/key"),
      "environment" => DEFAULT_SPEC["environment"].merge(
        "env" => { "ANTHROPIC_BASE_URL" => "https://rogue.example.com", "ANTHROPIC_API_KEY" => "inline-key", "FOO" => "bar" }
      )
    )
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner, resolver: echo_resolver).tick

      argv = spawner.argvs.first
      assert_includes argv, "ANTHROPIC_BASE_URL=https://api.example.com"
      assert argv.none? { |arg| arg.include?("rogue.example.com") }, "declared env must not shadow the backend base url"
      assert argv.none? { |arg| arg.start_with?("ANTHROPIC_API_KEY=") }, "inline key must yield to the secret transport"
      assert_equal 1, argv.count("ANTHROPIC_API_KEY"), "exactly one bare -e ANTHROPIC_API_KEY"
      assert_includes argv, "FOO=bar", "non-colliding declared env passes through"
      assert_equal "resolved-ANTHROPIC_API_KEY", spawner.envs.first["ANTHROPIC_API_KEY"]
    end
  end

  def test_network_permission_true_omits_network_flag
    make_job(
      "environment" => DEFAULT_SPEC["environment"].merge(
        "permissions" => { "network" => true, "mounts" => [] }
      )
    )
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner).tick
      refute_includes spawner.argvs.first, "--network"
    end
  end

  def test_escaping_mount_rejects_job_without_spawning
    job = make_job(
      "environment" => DEFAULT_SPEC["environment"].merge(
        "permissions" => { "network" => false, "mounts" => ["/data/../../etc:/etc"] }
      )
    )
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      redis.del(key_for(job))
      build_executor(redis: redis, spawner: spawner).tick

      assert_equal "failed", jobs_repo.by_pk(job.id).status
      assert_equal 0, spawner.calls
      assert_equal "exit", events(redis, key_for(job)).last[0]
    end
  end

  def test_relative_mount_rejects_job_without_spawning
    job = make_job(
      "environment" => DEFAULT_SPEC["environment"].merge(
        "permissions" => { "network" => false, "mounts" => ["relative/path:/data"] }
      )
    )
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner).tick
      assert_equal "failed", jobs_repo.by_pk(job.id).status
      assert_equal 0, spawner.calls
    end
  end

  # The stop path acts on the container by ID (I09 P5): the same cidfile must
  # reach both the argv (`--cidfile <path>`) and the spawner seam.
  def test_cidfile_threads_through_argv_and_spawner
    make_job
    spawner = FakeSpawner.new(FakeHandle.new)

    with_redis do |redis|
      build_executor(redis: redis, spawner: spawner).tick

      argv    = spawner.argvs.first
      cidfile = spawner.cidfiles.first
      refute_nil cidfile
      assert_equal cidfile, argv[argv.index("--cidfile") + 1]
      refute File.exist?(cidfile), "cidfile must be cleaned up after the run"
    end
  end

  def test_wall_clock_timeout_stops_then_kills
    job    = make_job
    handle = FakeHandle.new(hang: true)

    with_redis do |redis|
      redis.del(key_for(job))
      executor = build_executor(redis: redis, spawner: FakeSpawner.new(handle),
        timeout: 0.05, stop_grace: 0.05)
      executor.tick

      assert_equal 1, handle.stops
      assert_equal 1, handle.kills
      assert_equal "failed", jobs_repo.by_pk(job.id).status
      exits = events(redis, key_for(job)).select { |t, _| t == "exit" }
      assert_equal 1, exits.length
      assert_equal({ "code" => 137 }, JSON.parse(exits.first[1]))
    end
  end

  # --- cancellation (I14) ---

  # A running cancel is observed via the heartbeat coming back 0-row: the
  # executor stops the container through the same Handle stop-then-kill path
  # as a wall-clock timeout, but must skip the terminal write (status stays
  # "canceled", never clobbered to "failed") and must not emit an exit frame
  # onto the raw stream — the consumer already treats a canceled job as
  # producer-gone (Jobs::Consumer#producer_gone?).
  def test_running_cancel_stops_the_container_and_skips_the_terminal_write
    job    = make_job
    handle = FakeHandle.new(hang: true)

    with_redis do |redis|
      redis.del(key_for(job))
      executor = build_executor(redis: redis, spawner: FakeSpawner.new(handle),
        lease_seconds: 0.05, stop_grace: 0.05)

      Async::Task.current.async do
        sleep(0.03)
        jobs_repo.cancel(job.id)
      end

      executor.tick

      assert_equal 1, handle.stops
      assert_equal 1, handle.kills
      assert_equal "canceled", jobs_repo.by_pk(job.id).status
      assert_equal 0, events(redis, key_for(job)).count { |t, _| t == "exit" },
        "a canceled run must not emit a terminal exit frame"
    end
  end

  # A cancel landing between env-image build success and container spawn
  # (I46) must never reach the sandbox: no spawner call, no secrets resolved,
  # no exit frame — the consumer already treats a canceled producer as EOF.
  def test_cancel_during_env_build_skips_spawn_entirely
    job     = make_job
    spawner = FakeSpawner.new(FakeHandle.new)
    resolver_called = false

    with_redis do |redis|
      redis.del(key_for(job))
      executor = build_executor(redis: redis, spawner: spawner,
        env_image: ->(_environment) { jobs_repo.cancel(job.id); Success("img:abc123") },
        resolver: ->(_refs) { resolver_called = true; {} })
      executor.tick

      refute resolver_called, "a build-time cancel must skip secret resolution"
      assert_equal 0, spawner.calls, "a build-time cancel must never spawn the sandbox"
      assert_equal "canceled", jobs_repo.by_pk(job.id).status, "cancel must not be clobbered"
      assert_equal 0, events(redis, key_for(job)).count { |t, _| t == "exit" },
        "a build-time cancel must not emit a terminal exit frame"
    end
  end

  # --- run-row harness field (I17) ---

  def test_run_row_records_pi_harness_type
    job = make_job("harness" => DEFAULT_SPEC["harness"].merge("type" => "pi"))
    spawner = FakeSpawner.new(FakeHandle.new(stdout: "line\n", code: 0))

    with_redis do |redis|
      redis.del(key_for(job))
      build_executor(redis: redis, spawner: spawner).tick

      finished = jobs_repo.by_pk(job.id)
      run = runs_repo.by_pk(finished.run_id)
      assert_equal "pi", run.harness
    end
  end

  def test_tick_returns_nil_on_empty_queue
    with_redis do |redis|
      assert_nil build_executor(redis: redis, spawner: FakeSpawner.new).tick
    end
  end
end
