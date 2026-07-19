#!/usr/bin/env ruby
# frozen_string_literal: true

# DEV-ONLY single-process consumer worker. Production topology is `falcon host falcon.rb`.
#
# Polls Postgres for drainable jobs and drains each job's raw stream (job:<id>:raw,
# written by the executor) through Runs::Ingest into run:<id> display events and a
# persisted conversation. Stop with Ctrl-C (SIGINT) — the Async reactor's default
# SIGINT handling (Interrupt rescue in the reactor loop) stops the scheduler and
# exits cleanly without explicit signal traps.
#
# Usage: REDIS_URL=redis://localhost:6379 bundle exec ruby bin/consumer_worker.rb

require "hanami/boot"
require "async"

app = Space::Server::App
consumer = Space::Server::Jobs::Consumer.new(
  redis:              app["redis"],
  jobs_repo:          app["repos.jobs_repo"],
  runs_repo:          app["repos.runs_repo"],
  conversations_repo: app["repos.conversations_repo"],
  messages_repo:      app["repos.messages_repo"]
)

Console.logger.info(self, "Consumer worker starting (poll every #{Space::Server::Jobs::Consumer::POLL_SECONDS}s)")
Console.logger.info(self, "Stop with Ctrl-C — production topology: falcon host falcon.rb")

Async do
  consumer.start
end
