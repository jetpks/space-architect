# frozen_string_literal: true

require "async/job/processor/redis"
require "async/redis"
require "async/redis/endpoint"
require "async/semaphore"
require "sequel"

module Space
  module Server
    module Jobs
      class ImportConversation
        include Space::Server::Deps["repos.conversations_repo", "repos.messages_repo"]

        # DB-infrastructure errors: the importer never got a chance to persist
        # status:failed, so the job must be retried rather than left stranded.
        TRANSIENT_DB_ERRORS = [
          Sequel::PoolTimeout,
          Sequel::DatabaseConnectionError,
          Sequel::DatabaseDisconnectError
        ].freeze

        # Bounds concurrent imports strictly below the Sequel connection pool
        # (config/providers/db.rb:12 — max_connections: ENV.fetch("DB_POOL", "5").to_i,
        # the Sequel default of 5). Async::Job::Processor::Redis::Server#dequeue spawns
        # one fiber per job under an unbounded Async::Idler by default, so a bulk
        # backfill's concurrent dequeue can starve every pool connection and strand
        # the rest at Sequel::PoolTimeout.
        MAX_CONCURRENT_IMPORTS = 3

        def call(conversation_id)
          conversation = conversations_repo.by_pk(conversation_id)
          unless conversation
            Console.warn(self, "ImportConversation: conversation #{conversation_id} not found")
            return
          end

          sf = conversation.source_file
          unless sf
            Console.warn(self, "ImportConversation: conversation #{conversation_id} has no source_file")
            return
          end

          sf.open do |io|
            record = first_record(io)
            io.rewind
            Space::Server::Importers.select(record).new.import!(conversation, io)
          end

          imported = conversations_repo.with_messages(conversation.id)
          turns_count = Space::Server::Transcript::Turn.group(imported.messages).size
          conversations_repo.update(conversation.id, turns_count: turns_count)
        rescue *TRANSIENT_DB_ERRORS => e
          # DB-infrastructure failure (pool exhaustion / connection loss) — the importer
          # never got a chance to persist status:failed, so the row would be stranded at
          # status:pending forever if swallowed. Re-raise so async-job's retry-forever
          # loop (server.rb dequeue rescue -> processing_list.retry) re-fires this job.
          Console.error(self, "ImportConversation transient DB error for id=#{conversation_id}, will retry", exception: e)
          raise
        rescue => e
          # Importer already persisted status:failed before re-raising.
          # Swallow here so async-job's retry-forever loop (server.rb dequeue rescue ->
          # processing_list.retry) never fires for permanent import failures.
          Console.error(self, "ImportConversation failed for id=#{conversation_id}", exception: e)
        end

        # Build a Processor::Redis for this job type.
        # Used by bin/import_worker.rb and the Redis integration test — same construction in both.
        # parent: nil → Server uses Async::Idler (correct for the long-running worker process).
        # parent: task → Server tasks become children of task (needed in tests for clean teardown).
        def self.build_redis_processor(endpoint: nil, prefix: "architect-import", parent: nil)
          ep = endpoint || begin
            url = ENV["REDIS_URL"]
            url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
          end
          opts = { endpoint: ep, prefix: prefix }
          opts[:parent] = parent if parent
          Async::Job::Processor::Redis.new(Delegate.new, **opts)
        end

        # Delegate wired into the async-job processor.
        # Instantiated fresh per provider start; routes each job hash to a fresh job body.
        #
        # The Redis server (async-job-processor-redis) spawns one fiber per dequeued job
        # under an unbounded parent, so the concurrency bound has to live here, around the
        # actual DB-touching work, rather than on the dequeue loop itself. `importer:` is
        # a constructor-injection seam for tests (defaults to the real ImportConversation).
        class Delegate
          def initialize(semaphore: Async::Semaphore.new(ImportConversation::MAX_CONCURRENT_IMPORTS), importer: ImportConversation)
            @semaphore = semaphore
            @importer  = importer
          end

          def call(job)
            @semaphore.acquire { @importer.new.call(job["conversation_id"]) }
          end

          def start; end
          def stop; end
        end

        private

        def first_record(io)
          io.each_line do |line|
            next if line.strip.empty?
            begin
              return JSON.parse(line)
            rescue JSON::ParserError
              next
            end
          end
          nil
        end
      end
    end
  end
end
