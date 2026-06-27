# frozen_string_literal: true

require "async/job/processor/redis"
require "async/redis"
require "async/redis/endpoint"

module Architect
  module Jobs
    class ImportConversation
      include Architect::Deps["repos.conversations_repo", "repos.messages_repo"]

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
          Architect::Importers.select(record).new.import!(conversation, io)
        end
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
      class Delegate
        def call(job)
          ImportConversation.new.call(job["conversation_id"])
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
