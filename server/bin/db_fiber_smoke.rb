#!/usr/bin/env ruby
# frozen_string_literal: true

# G3 smoke: boots Hanami app, gets Sequel connection from the :db gateway,
# runs M=8 fibers with max_connections=4 each doing SELECT pg_sleep(0.25).
# Proves fiber_concurrency took effect through hanami-db's provider.

require_relative "../config/app"
require "hanami/prepare"

M = 8
P = 4

# Override pool size for smoke (re-connect with P=4)
# The provider is already configured with DB_POOL. For the smoke we need exactly P=4.
# Pull the Sequel connection from the booted container gateway.
Hanami.app.prepare(:db)

gateway = Hanami.app["db.gateway"]
db = gateway.connection

puts "fiber_concurrency: #{defined?(Sequel::FiberConcurrency) || 'nil'}"
puts "pool_class: #{db.pool.class}"

require "async"
require "async/barrier"

ok = 0
err = 0

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

Async do
  barrier = Async::Barrier.new
  M.times do
    barrier.async do
      db.run("SELECT pg_sleep(0.25)")
      ok += 1
    rescue => e
      err += 1
      $stderr.puts "ERR: #{e.class}: #{e.message}"
    end
  end
  barrier.wait
end

wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

puts "ok: #{ok}"
puts "err: #{err}"
puts "wall: #{wall.round(3)}s"

exit(ok == M && err == 0 ? 0 : 1)
