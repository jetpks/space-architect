# frozen_string_literal: true

require "sequel"
# Process-wide: flips Sequel.current -> Fiber.current before any Sequel.connect.
# Loaded by dry-system's ProviderRegistrar before the :db provider's #prepare runs.
# Injection point: hanami-2.3.2/lib/hanami/slice.rb:959 (loads this file)
# Connect happens at: hanami-2.3.2/lib/hanami/providers/db.rb:47 (prepare_gateways)
Sequel.extension :fiber_concurrency

Hanami.app.configure_provider :db do
  config.gateway :default do |gw|
    gw.connection_options(max_connections: ENV.fetch("DB_POOL", "5").to_i)
  end
end
