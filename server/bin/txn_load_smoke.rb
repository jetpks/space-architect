#!/usr/bin/env ruby
# frozen_string_literal: true

# C2 smoke: nested transactions (savepoints) under fiber concurrency.
# Verifies re-entrancy correctness with the stock :timed_queue pool and
# Sequel.extension :fiber_concurrency.
#
# Usage: bundle exec ruby bin/txn_load_smoke.rb
# Env:  DB_POOL=<n>  (defaults to 5, set in config/providers/db.rb)

require_relative "../test/test_helper"
require "async"

FIBER_COUNT   = Integer(ENV.fetch("FIBER_COUNT", "10"))
EXPECTED_ROWS = FIBER_COUNT  # each fiber commits exactly 1 user row
SMOKE_TIMEOUT = 30           # seconds

conn = Architect::App["db.gateway"].connection

fiber_concurrency_on = Sequel.current == Fiber.current

puts "=== C2 smoke ==="
puts "fiber_concurrency extension: #{fiber_concurrency_on ? 'ON (Sequel.current == Fiber.current)' : 'OFF'}"
puts "pool class: #{conn.pool.class}"
puts "fiber count: #{FIBER_COUNT}"
puts

# Confirm fiber_concurrency is active (loaded in config/providers/db.rb)
raise "Sequel :fiber_concurrency extension must be ON" unless fiber_concurrency_on

# Confirm stock timed_queue pool (no custom pool_class)
raise "Expected Sequel::TimedQueueConnectionPool" unless conn.pool.is_a?(Sequel::TimedQueueConnectionPool)

# Seed table reference: use users (already created by migration)
# Clean up any smoke-tagged rows from prior runs
conn[:users].where(Sequel.like(:username, "smoke_%")).delete

puts "Running #{FIBER_COUNT} concurrent fibers each with outer+savepoint transaction..."

errors    = []
committed = []

Async do |task|
  task.with_timeout(SMOKE_TIMEOUT) do
    FIBER_COUNT.times.map do |i|
      task.async do
        conn.transaction do
          # Outer write: will commit if inner savepoint succeeds
          uid  = "smoke_uid_#{i}_#{SecureRandom.hex(4)}"
          name = "smoke_#{i}_outer"

          # Deliberate rollback of savepoint: this write must NOT appear
          begin
            conn.transaction(savepoint: true) do
              conn[:users].insert(
                github_uid:  "#{uid}_discarded",
                username:    "smoke_#{i}_discarded",
                github_orgs: Sequel.pg_jsonb([]),
                created_at:  Time.now,
                updated_at:  Time.now
              )
              raise Sequel::Rollback  # roll back savepoint only
            end
          rescue => e
            # Sequel::Rollback is handled by Sequel; any other error propagates
            raise unless e.is_a?(Sequel::Rollback)
          end

          # The savepoint rollback must NOT have killed the outer transaction.
          # Insert the real row.
          conn[:users].insert(
            github_uid:  uid,
            username:    name,
            github_orgs: Sequel.pg_jsonb([]),
            created_at:  Time.now,
            updated_at:  Time.now
          )
        end

        committed << i
      end
    end.each(&:wait)
  end
rescue => e
  errors << e
end

puts "Fibers completed: #{committed.size} / #{FIBER_COUNT}"

# Verify row count
actual = conn[:users].where(Sequel.like(:username, "smoke_%_outer")).count
puts "Rows in DB matching outer writes: #{actual} (expected #{EXPECTED_ROWS})"

# Discarded rows must not exist
discarded = conn[:users].where(Sequel.like(:username, "smoke_%_discarded")).count
puts "Rows from rolled-back savepoints: #{discarded} (expected 0)"

# Cleanup
conn[:users].where(Sequel.like(:username, "smoke_%")).delete
puts "Cleaned up smoke rows."

if errors.any?
  puts "\nFAILURE — exceptions:"
  errors.each { |e| puts "  #{e.class}: #{e.message}" }
  exit 1
end

if committed.size != FIBER_COUNT
  puts "\nFAILURE — only #{committed.size}/#{FIBER_COUNT} fibers completed"
  exit 1
end

if actual != EXPECTED_ROWS
  puts "\nFAILURE — expected #{EXPECTED_ROWS} committed rows, got #{actual}"
  exit 1
end

if discarded != 0
  puts "\nFAILURE — #{discarded} savepoint-rolled-back rows leaked into DB"
  exit 1
end

puts "\nPASS — all #{FIBER_COUNT} nested transactions committed; savepoint rollback correct; no leaks."
exit 0
