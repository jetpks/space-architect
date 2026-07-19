# frozen_string_literal: true

require "falcon/environment/rack"
require "async/service/managed/service"
require "async/service/managed/environment"
require_relative "app/services/import_worker_service"
require_relative "app/services/executor_worker_service"
require_relative "app/services/consumer_worker_service"

# Web service: serves the Rack app (config.ru) on plain HTTP.
#
# Falcon::Environment::Rack includes Application which overrides endpoint to a Unix IPC socket
# (designed for virtual-host reverse-proxy topology). We override endpoint to bind plain TCP HTTP
# so both the web service and the boot-smoke probe work without a separate proxy layer.
service "architect.web" do
  include Falcon::Environment::Rack

  endpoint { Async::HTTP::Endpoint.parse("http://localhost:3000") }
end

# Import-worker service: a single managed child process that dequeues from Redis
# and runs Space::Server::Jobs::ImportConversation for each job. Supervised and
# restarted by async-container on failure. Stop is container-driven — no signal traps.
service "architect.import-worker" do
  include Async::Service::Managed::Environment

  service_class { Space::Server::Services::ImportWorkerService }

  count 1
  redis_prefix { "architect-import" }
end

# Executor-worker service: a single managed child process that polls Postgres
# for queued inference jobs and runs each in the container sandbox, relaying
# harness output onto job:<id>:raw. Stop is container-driven — no signal traps.
service "architect.executor-worker" do
  include Async::Service::Managed::Environment

  service_class { Space::Server::Services::ExecutorWorkerService }

  count 1
end

# Consumer-worker service: a single managed child process that drains executor
# raw streams into run:<id> display events and persisted conversations.
# Stop is container-driven — no signal traps.
service "architect.consumer-worker" do
  include Async::Service::Managed::Environment

  service_class { Space::Server::Services::ConsumerWorkerService }

  count 1
end
