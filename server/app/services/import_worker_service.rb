# auto_register: false
# frozen_string_literal: true

require "async/service/managed/service"

module Space
  module Server
    module Services
      # Managed async-service child that dequeues import jobs from Redis.
      #
      # Runs as a supervised process under `falcon host falcon.rb`. Graceful stop is
      # container-driven: when async-container terminates the child, Async::Stop propagates
      # through the reactor, the background fiber's ensure block calls server.stop, and the
      # process exits cleanly — no signal traps.
      class ImportWorkerService < Async::Service::Managed::Service
        # Called inside the child process, inside the Async reactor.
        # Boots the app, starts the Redis processor in a background fiber, and returns
        # the server object synchronously (used by Managed::Service for format_title and
        # instance.ready!).
        def run(instance, evaluator)
          require "hanami/boot"

          prefix = evaluator.respond_to?(:redis_prefix) ? evaluator.redis_prefix : "architect-import"
          server = Space::Server::Jobs::ImportConversation.build_redis_processor(prefix: prefix)

          Console.info(self) { "Import worker starting (prefix=#{prefix})" }

          Async::Task.current.async do
            server.start
            sleep
          ensure
            server.stop rescue nil
          end

          server
        end
      end
    end
  end
end
