# auto_register: false
# frozen_string_literal: true

require "async/service/managed/service"
require "open3"

module Space
  module Server
    module Services
      # Managed async-service child that polls Postgres for queued inference
      # jobs and runs each in the container sandbox.
      #
      # Runs as a supervised process under `falcon host falcon.rb`. Graceful stop is
      # container-driven: when async-container terminates the child, Async::Stop propagates
      # through the reactor, the background fiber's ensure block calls executor.stop, and the
      # process exits cleanly — no signal traps.
      class ExecutorWorkerService < Async::Service::Managed::Service
        # Called inside the child process, inside the Async reactor.
        # Boots the app, starts the poll loop in a background fiber, and returns
        # the executor object synchronously (used by Managed::Service for
        # format_title and instance.ready!).
        def run(instance, evaluator)
          require "hanami/boot"

          executor = Space::Server::Jobs::Executor.new(
            jobs_repo: Space::Server::App["repos.jobs_repo"],
            runs_repo: Space::Server::App["repos.runs_repo"],
            redis:     Space::Server::App["redis"],
            env_image: Space::Server::Jobs::EnvImage.new(
              spawn:      Open3.method(:capture2e),
              base_image: ENV.fetch("JOB_ENV_BASE_IMAGE", Space::Server::Jobs::EnvImage::DEFAULT_BASE_IMAGE)
            )
          )

          Console.info(self) { "Executor worker starting (poll interval=#{Space::Server::Jobs::Executor::DEFAULT_INTERVAL}s)" }

          Async::Task.current.async do
            executor.run
          ensure
            executor.stop
          end

          executor
        end
      end
    end
  end
end
