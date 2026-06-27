# frozen_string_literal: true

require_relative "../test_helper"
require "async"
require "async/job/processor/redis"
require "async/redis"
require "async/redis/endpoint"
require "securerandom"

# Integration test: enqueue → Redis → real round-trip → import completes.
# Uses the SAME Processor::Redis construction as bin/import_worker.rb via
# ImportConversation.build_redis_processor(prefix:).
# Skips ONLY when Redis is unreachable; must execute and pass under live Redis.
class ImportRedisIntegrationTest < Minitest::Test
  REDIS_SKIP_MSG = "Redis unreachable".freeze

  def conn = @conn ||= Architect::App["db.gateway"].connection
  def conversations_repo = Architect::Repos::ConversationsRepo.new

  def fixture_path(name)
    File.join(__dir__, "..", "fixtures", "files", name)
  end

  def redis_reachable?
    ep = if (url = ENV["REDIS_URL"])
      Async::Redis::Endpoint.parse(url)
    else
      Async::Redis.local_endpoint
    end
    Sync do
      client = Async::Redis::Client.new(ep)
      client.call("PING")
      client.close
      true
    rescue
      false
    end
  end

  def setup
    skip REDIS_SKIP_MSG unless redis_reachable?
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each { |t| conn[t].delete }
  end

  def test_redis_round_trip_imports_conversation
    data = Architect::SourceFileUploader.store(File.open(fixture_path("transcript.jsonl")))
    conv = Factory[:conversation, source_file_data: data]

    # Unique prefix per run prevents collision with any live worker queue
    prefix = "architect-test-#{SecureRandom.hex(8)}"

    Sync do |task|
      # Build server without parent: — @parent = Async::Idler, which resolves
      # Task.current at spawn time. Since server.start is called from inside
      # server_task below, ALL server sub-tasks (dequeue loop, delayed_jobs bg,
      # processing_list bg) become children of server_task's inner fiber.
      server = Architect::Jobs::ImportConversation.build_redis_processor(prefix: prefix)

      # Enqueue before starting the server (pure Redis write — no tasks needed)
      server.call({ "conversation_id" => conv.id })

      # server_task owns all server sub-tasks. Stopping it tears down:
      #   - @delayed_jobs background loop (child of the inner task)
      #   - @processing_list heartbeat loop (child of the inner task)
      #   - the main dequeue loop (Idler resolves Task.current → inner task at spawn)
      server_task = task.async do |t|
        server.start
        sleep(Float::INFINITY)  # keep alive; server_task.stop raises Async::Stop here
      end

      begin
        # 15-second backstop: TimeoutError aborts everything and the test fails
        # with a clear message if the import doesn't complete.
        task.with_timeout(15) do
          loop do
            sleep(0.1)
            status = conversations_repo.by_pk(conv.id)&.status
            break if status == :completed || status == :failed
          end
        end
      ensure
        # Stop server_task and all its children — guaranteed cleanup regardless
        # of whether the block completed normally or timed out.
        server_task.stop
      end
    end

    conv = conversations_repo.by_pk(conv.id)
    assert_equal :completed, conv.status,
      "Expected :completed after Redis round-trip (got #{conv.status.inspect})"
  end
end
