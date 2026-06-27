#!/usr/bin/env ruby
# frozen_string_literal: true

# DEV-ONLY single-process import worker. Production topology is `falcon host falcon.rb`.
#
# Dequeues job hashes from Redis and runs Architect::Jobs::ImportConversation for each.
# Stop with Ctrl-C (SIGINT) — the Async reactor's default SIGINT handling (Interrupt rescue
# in the reactor loop) stops the scheduler and exits cleanly without explicit signal traps.
#
# Usage: REDIS_URL=redis://localhost:6379 bundle exec ruby bin/import_worker.rb

require "hanami/boot"
require "async"

server = Architect::Jobs::ImportConversation.build_redis_processor

Console.logger.info(self, "Import worker starting (prefix=architect-import)")
Console.logger.info(self, "Stop with Ctrl-C — production topology: falcon host falcon.rb")

Async do
  server.start
  Async::Task.current.sleep
end
