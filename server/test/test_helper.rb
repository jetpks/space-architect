# frozen_string_literal: true

ENV["HANAMI_ENV"] ||= "test"

# Silence expected test noise before any requires so gem-load warnings
# are suppressed too:
#   $VERBOSE      — stub redefinitions and gem internals (async-redis, resolv)
#   OmniAuth      — auth-failure tests log ERROR by design
#   Console       — import-worker structured logs (info/warn/error) are test fixtures
$VERBOSE = false
Warning[:experimental] = false
require "hanami/prepare"
require "minitest/autorun"
require "omniauth"
require "console"
require "async"
require "async/redis"
require "async/redis/endpoint"
require_relative "factories"

OmniAuth.config.logger = Logger.new(File::NULL)
Console.logger.level = :fatal

# Flush the isolated test Redis database once at suite boot. REDIS_URL (set in
# .env.test, loaded above by hanami/prepare) must point at a non-zero database —
# dev runs against db 0, and this suite's XADDs (display streams, job raw logs)
# must never land there. Guarded rather than assumed: a misconfigured or absent
# REDIS_URL fails the suite loudly instead of silently flushing dev's db 0.
Sync do
  url = ENV["REDIS_URL"]
  raise "REDIS_URL must be set for the test suite (an isolated, non-zero database)" unless url

  endpoint = Async::Redis::Endpoint.parse(url)
  raise "REDIS_URL must select a database other than 0 (got #{endpoint.database.inspect}); " \
        "dev runs against db 0 and the suite must never flush it" if endpoint.database.to_i.zero?

  client = Async::Redis::Client.new(endpoint)
  client.call("FLUSHDB")
  client.close
end

# Force-load conversation_share.rb before any test runs so that
# Space::Server::Structs::Share is defined as a ConversationShare subclass
# before ROM's struct compiler ever processes the :shares combine alias.
# Without this, a seed-dependent race exists: the combine fires first,
# ROM pre-creates Share < ROM::Struct, and subsequent file loading raises
# TypeError: superclass mismatch for class Share.
_ = Space::Server::Structs::ConversationShare

# minitest 6 dropped minitest/mock. This stub shim allows swapping a named
# singleton method for a value or callable within a block, then restoring it.
# Mirrors the Rails test_helper implementation used in the oracle test suite.
class Object
  def stub(name, val_or_callable)
    original = method(name)
    define_singleton_method(name) do |*args, **kwargs, &block|
      if val_or_callable.respond_to?(:call)
        val_or_callable.call(*args, **kwargs, &block)
      else
        val_or_callable
      end
    end
    yield
  ensure
    define_singleton_method(name, original)
  end
end
