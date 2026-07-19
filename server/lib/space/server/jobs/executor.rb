# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require_relative "executor/raw_stream"
require_relative "executor/sandbox_argv"
require_relative "executor/secret_resolver"
require_relative "executor/process_spawner"

module Space
  module Server
    module Jobs
      # Inference-job executor: polls Postgres (the queue of record) for queued
      # jobs and runs each in the container sandbox, relaying harness output
      # onto the frozen raw stream (job:<id>:raw). Crash safety lives in PG —
      # an executor that dies mid-job lets the lease expire and the sweep
      # requeues it (capped by attempts). A job that RAN and exited nonzero is
      # failed, never retried. Fibers all the way down; no threads.
      class Executor
        DEFAULT_INTERVAL      = 2
        DEFAULT_LEASE_SECONDS = 60
        DEFAULT_MAX_ATTEMPTS  = 3
        DEFAULT_TIMEOUT       = 3600
        DEFAULT_STOP_GRACE    = 10
        ENV_BUILD_EXIT_CODE   = 1

        def initialize(jobs_repo:, runs_repo:, redis:, env_image:,
                       secret_resolver: SecretResolver.new, spawner: ProcessSpawner.new,
                       interval: DEFAULT_INTERVAL, lease_seconds: DEFAULT_LEASE_SECONDS,
                       max_attempts: DEFAULT_MAX_ATTEMPTS, timeout: DEFAULT_TIMEOUT,
                       stop_grace: DEFAULT_STOP_GRACE)
          @jobs_repo       = jobs_repo
          @runs_repo       = runs_repo
          @redis           = redis
          @env_image       = env_image
          @secret_resolver = secret_resolver
          @spawner         = spawner
          @interval        = interval
          @lease_seconds   = lease_seconds
          @max_attempts    = max_attempts
          @timeout         = timeout
          @stop_grace      = stop_grace
        end

        # Poll loop; run under the Async reactor. Sleeps between empty polls.
        def run
          @running = true
          while @running
            tick || sleep(@interval)
          end
        end

        def stop = @running = false

        # One poll cycle: sweep stale leases, claim, execute.
        # Returns the claimed job, or nil when the queue is empty.
        def tick
          @jobs_repo.sweep_stale(max_attempts: @max_attempts)
          job = @jobs_repo.claim(lease_seconds: @lease_seconds)
          return unless job

          execute(job)
          job
        end

        private

        # claim → run row → env image → secrets → sandbox. Unexpected errors
        # are logged and swallowed: the job stays running until its lease
        # expires and the sweep requeues it (the crash-recovery path).
        def execute(job)
          stream = RawStream.new(@redis, job.id)
          create_run(job)
          @env_image.call(job.spec["environment"]).either(
            ->(image_tag) { run_sandbox(job, image_tag, stream) },
            ->(build_log) { fail_before_spawn(job, build_log, stream) }
          )
        rescue => e
          Console.error(self, "Executor: job #{job.id} crashed", exception: e)
        end

        def create_run(job)
          now = Time.now
          run = @runs_repo.create(
            user_id:    job.user_id,
            harness:    "claude",
            model:      job.spec.dig("harness", "model"),
            status:     0,
            created_at: now,
            updated_at: now
          )
          @jobs_repo.update(job.id, run_id: run.id)
          run
        end

        # The cidfile lets the stop path signal the container itself — client
        # signals never stop it under Apple `container` 1.0.0 (I09 P5).
        def run_sandbox(job, image_tag, stream)
          cidfile = File.join(Dir.tmpdir, "space-job-#{job.id}-#{SecureRandom.hex(4)}.cid")
          SandboxArgv.build(job.spec, image_tag, cidfile: cidfile).either(
            ->(argv) { spawn_and_relay(job, argv, stream, cidfile) },
            ->(reason) { fail_before_spawn(job, reason, stream) }
          )
        end

        # No sandbox ran: leave the evidence (build log / rejection reason) on
        # the raw stream as err lines, terminate the stream, fail the job.
        def fail_before_spawn(job, evidence, stream)
          evidence.to_s.each_line { |line| stream.err(line.chomp) }
          stream.exit(ENV_BUILD_EXIT_CODE)
          @jobs_repo.mark_failed(job.id)
        end

        def spawn_and_relay(job, argv, stream, cidfile)
          secrets = @secret_resolver.call(secret_refs(job.spec))
          handle  = @spawner.call(argv, env: secrets, cidfile: cidfile)
          code    = supervise(job, handle, stream)
          stream.exit(code)
          code.zero? ? @jobs_repo.mark_succeeded(job.id) : @jobs_repo.mark_failed(job.id)
        ensure
          File.delete(cidfile) if File.exist?(cidfile)
        end

        # environment.secrets plus the backend api-key ref (when present),
        # appended last so the backend value wins any name collision in the
        # resolved spawn env. Values ride ONLY there — never argv.
        def secret_refs(spec)
          refs = spec.dig("environment", "secrets") || []
          ref  = spec.dig("harness", "backend", "api_key_ref")
          ref ? refs + [{ "name" => SandboxArgv::API_KEY_ENV, "ref" => ref }] : refs
        end

        # One fiber per child stream pumps output onto the raw stream while the
        # parent fiber awaits exit under the wall-clock deadline; a heartbeat
        # fiber extends the PG lease so a live job is never swept mid-run.
        def supervise(job, handle, stream)
          Sync do |task|
            pumps = [
              task.async { pump(handle.stdout) { |line| stream.out(line) } },
              task.async { pump(handle.stderr) { |line| stream.err(line) } }
            ]
            beat = heartbeat(task, job)
            code = await_exit(task, handle)
            pumps.each(&:wait)
            beat.stop
            code
          end
        end

        def pump(io)
          while (line = io.gets)
            yield line.chomp
          end
        ensure
          io.close unless io.closed?
        end

        def heartbeat(task, job)
          task.async do
            loop do
              task.sleep(@lease_seconds / 2.0)
              @jobs_repo.heartbeat(job.id, lease_seconds: @lease_seconds)
            end
          end
        end

        # Wall-clock deadline: graceful stop at @timeout, kill after @stop_grace.
        def await_exit(task, handle)
          task.with_timeout(@timeout) { handle.wait }
        rescue Async::TimeoutError
          handle.stop
          begin
            task.with_timeout(@stop_grace) { handle.wait }
          rescue Async::TimeoutError
            handle.kill
            handle.wait
          end
        end
      end
    end
  end
end
