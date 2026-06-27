# frozen_string_literal: true

require "async/job/processor/inline"
require "async/job/processor/redis"
require "async/redis"
require "async/redis/endpoint"

Hanami.app.register_provider(:import_queue) do
  start do
    delegate = Space::Server::Jobs::ImportConversation::Delegate.new

    processor = if Hanami.env?(:test)
      Async::Job::Processor::Inline.new(delegate)
    else
      Space::Server::Jobs::ImportConversation.build_redis_processor
    end

    register("import_queue", processor)
  end
end
