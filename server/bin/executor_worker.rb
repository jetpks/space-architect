#!/usr/bin/env ruby
# frozen_string_literal: true

# DEV-ONLY single-process inference-job executor. Production topology is `falcon host falcon.rb`.
#
# Polls Postgres (the queue of record) for queued jobs and runs each in the container
# sandbox via Space::Server::Jobs::Executor, relaying harness output onto job:<id>:raw.
# Stop with Ctrl-C (SIGINT) — the Async reactor's default SIGINT handling stops the
# scheduler and exits cleanly without explicit signal traps.
#
# Usage: REDIS_URL=redis://localhost:6379 bundle exec ruby bin/executor_worker.rb

require "hanami/boot"
require "async"

executor = Space::Server::Jobs::Executor.new(
  jobs_repo: Space::Server::App["repos.jobs_repo"],
  runs_repo: Space::Server::App["repos.runs_repo"],
  redis:     Space::Server::App["redis"],
  env_image: Space::Server::Jobs::EnvImage.new
)

Console.logger.info(self, "Executor worker starting (poll interval=#{Space::Server::Jobs::Executor::DEFAULT_INTERVAL}s)")
Console.logger.info(self, "Stop with Ctrl-C — production topology: falcon host falcon.rb")

Async do
  executor.run
end
