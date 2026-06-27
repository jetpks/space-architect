# frozen_string_literal: true

require "async/redis"
require "async/redis/endpoint"

Hanami.app.register_provider(:redis) do
  start do
    url = ENV["REDIS_URL"]
    endpoint = url ? Async::Redis::Endpoint.parse(url) : Async::Redis.local_endpoint
    register("redis", Async::Redis::Client.new(endpoint))
  end
end
