# frozen_string_literal: true

require "async"
require_relative "../runs/ingest"
require_relative "../runs/persistor"
require_relative "consumer/raw_stream"

module Space
  module Server
    module Jobs
      # Drains executor raw streams (job:<id>:raw) into the existing display
      # pipeline: Runs::Ingest normalizes each harness stdout line, XADDs
      # display events onto run:<id> (served live by the SSE action), and
      # persists the conversation + messages via Runs::Persistor.
      #
      # Drain state is the run itself: a job is drainable while its run is
      # absent or non-terminal; a terminal run marks the job drained. Re-drains
      # replace the conversation wholesale (fresh-conversation restart safety),
      # so the run only ever links one. Job status belongs to the executor and
      # is never written here.
      class Consumer
        DRAINABLE_STATUSES = %w[running succeeded failed].freeze
        POLL_SECONDS = 2
        SOURCE = "job"

        def initialize(redis:, jobs_repo:, runs_repo:, conversations_repo:, messages_repo:)
          @redis              = redis
          @jobs_repo          = jobs_repo
          @runs_repo          = runs_repo
          @conversations_repo = conversations_repo
          @messages_repo      = messages_repo
          @active             = {}
        end

        # Long-running worker loop; sleep is non-blocking under the Async scheduler.
        def start
          loop do
            poll
            sleep POLL_SECONDS
          end
        end

        # One discovery pass: spawn a drain fiber per drainable job. Returns the
        # spawned tasks so callers (tests, future supervisors) can wait on them.
        def poll(parent: Async::Task.current)
          drainable_jobs.map do |job|
            @active[job.id] = true
            parent.async do
              drain(job)
            ensure
              @active.delete(job.id)
            end
          end
        end

        # PG poll: jobs the executor has started (or finished) whose run is
        # absent or non-terminal — run terminality is the drained marker.
        def drainable_jobs
          @jobs_repo.jobs.where(status: DRAINABLE_STATUSES).to_a.reject do |job|
            @active.key?(job.id) || drained?(job)
          end
        end

        # Drain one job's raw stream end-to-end, mirroring the ingest action's
        # run lifecycle: pending → live at drain start; at EOF complete only
        # when Ingest reports :complete AND the harness exited 0, else failed;
        # conversation_id linked from the persistor either way.
        def drain(job)
          run = ensure_run(job)
          @runs_repo.update(run.id, status: 1, updated_at: Time.now) if run.pending?

          raw       = RawStream.new(@redis, job.id, abandoned: -> { producer_gone?(job.id) })
          persistor = Runs::Persistor.new(@conversations_repo, @messages_repo)
          result    = Runs::Ingest.new(@redis, persistor: persistor, source: SOURCE).call(run, raw)
          exit_code = raw.drain_to_exit

          final = result[:status] == :complete && exit_code == 0 ? 2 : 3
          @runs_repo.update(run.id, status: final, conversation_id: persistor.conversation_id, updated_at: Time.now)
        end

        private

        def drained?(job)
          return false unless job.run_id

          run = @runs_repo.by_pk(job.run_id)
          !run.nil? && (run.complete? || run.failed?)
        end

        def ensure_run(job)
          run = job.run_id && @runs_repo.by_pk(job.run_id)
          return run if run

          now = Time.now
          run = @runs_repo.create(user_id: job.user_id, status: 0, published: false, created_at: now, updated_at: now)
          @jobs_repo.update(job.id, run_id: run.id, updated_at: now)
          run
        end

        # The executor is done (or the job vanished): no further raw entries are
        # coming, so a quiet stream means EOF rather than "keep waiting".
        def producer_gone?(job_id)
          job = @jobs_repo.by_pk(job_id)
          job.nil? || job.succeeded? || job.failed? || job.canceled?
        end
      end
    end
  end
end
