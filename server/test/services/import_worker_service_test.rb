# frozen_string_literal: true

require_relative "../test_helper"
require "async"
require "async/redis"
require "async/redis/endpoint"
require "securerandom"
require "async/service/managed/environment"
require "async/service/environment"
require_relative "../../app/services/import_worker_service"

# Lifecycle test for ImportWorkerService.
# Drives the service_class directly (no subprocess fork): calls run(instance, evaluator)
# in-reactor, enqueues a real Redis job, observes it drain to :completed, then stops.
# Mirrors the round-trip pattern of import_redis_integration_test.rb using the same
# build_redis_processor construction.
class ImportWorkerServiceTest < Minitest::Test
  REDIS_SKIP_MSG = "Redis unreachable".freeze

  def conn = @conn ||= Architect::App["db.gateway"].connection
  def conversations_repo = Architect::Repos::ConversationsRepo.new

  def fixture_path(name)
    File.join(__dir__, "..", "fixtures", "files", name)
  end

  def redis_reachable?
    ep = ENV["REDIS_URL"] ? Async::Redis::Endpoint.parse(ENV["REDIS_URL"]) : Async::Redis.local_endpoint
    Sync do
      client = Async::Redis::Client.new(ep)
      client.call("PING")
      client.close
      true
    rescue
      false
    end
  end

  def build_environment(prefix:)
    env_module = Module.new do
      include Async::Service::Managed::Environment

      define_method(:name) { "test-import-worker" }
      define_method(:root) { Dir.pwd }
      define_method(:redis_prefix) { prefix }
    end
    Async::Service::Environment.new(env_module)
  end

  def setup
    skip REDIS_SKIP_MSG unless redis_reachable?
    Faker::Internet.unique.clear
    Faker::Number.unique.clear
    [:annotations, :conversation_shares, :messages, :conversations, :users].each { |t| conn[t].delete }
  end

  def test_service_lifecycle_processes_job
    data = Architect::SourceFileUploader.store(File.open(fixture_path("transcript.jsonl")))
    conv = Factory[:conversation, source_file_data: data]

    prefix = "architect-svc-test-#{SecureRandom.hex(8)}"
    environment = build_environment(prefix: prefix)
    evaluator = environment.evaluator
    service = Architect::Services::ImportWorkerService.new(environment, evaluator)

    Sync do |task|
      service.start

      # Call run directly (bypasses container.run / subprocess fork) to drive the service
      # in-reactor. server is the Async::Job::Processor::Redis instance.
      server_task = task.async do
        service.run(nil, evaluator)
        sleep
      end

      # Enqueue a job using a client-side call to build_redis_processor with the same prefix.
      enqueue_server = Architect::Jobs::ImportConversation.build_redis_processor(prefix: prefix)
      enqueue_server.call({ "conversation_id" => conv.id })

      begin
        # 15-second hard timeout: TimeoutError → test fails with clear message, no spurious pass.
        task.with_timeout(15) do
          loop do
            sleep(0.1)
            status = conversations_repo.by_pk(conv.id)&.status
            break if status == :completed || status == :failed
          end
        end
      ensure
        server_task.stop
        service.stop(true)
      end
    end

    assert_equal :completed, conversations_repo.by_pk(conv.id).status,
      "Expected :completed after service lifecycle round-trip"
  end
end
