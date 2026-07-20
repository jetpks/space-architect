# auto_register: false
# frozen_string_literal: true

require "async/service/managed/service"

module Space
  module Server
    module Services
      # Managed async-service child that drains executor raw streams into the
      # display pipeline (run:<id> events + persisted conversations).
      #
      # Runs as a supervised process under `falcon host falcon.rb`. Graceful stop is
      # container-driven: when async-container terminates the child, Async::Stop propagates
      # through the reactor and unwinds the consumer's poll loop (and its drain fibers,
      # children of the same task) — no stop verb, no signal traps.
      class ConsumerWorkerService < Async::Service::Managed::Service
        # Called inside the child process, inside the Async reactor.
        # Boots the app, starts the poll loop in a background fiber, and returns
        # the consumer object synchronously (used by Managed::Service for
        # format_title and instance.ready!).
        def run(instance, evaluator)
          require "hanami/boot"

          app = Space::Server::App
          consumer = Space::Server::Jobs::Consumer.new(
            redis:              app["redis"],
            jobs_repo:          app["repos.jobs_repo"],
            runs_repo:          app["repos.runs_repo"],
            conversations_repo: app["repos.conversations_repo"],
            messages_repo:      app["repos.messages_repo"]
          )

          Console.info(self) { "Consumer worker starting (poll every #{Space::Server::Jobs::Consumer::POLL_SECONDS}s)" }

          Async::Task.current.async do
            consumer.start
          end

          consumer
        end
      end
    end
  end
end
