# frozen_string_literal: true

require "delegate"

module Space
  module Server
    module Jobs
      class Consumer
        # Runs::Ingest calls persistor.setup(run) with no source argument, so the
        # conversation source for job drains is pinned here at construction
        # instead of falling back to Persistor's "architect_dispatch" default.
        class SourcedPersistor < SimpleDelegator
          def initialize(persistor, source:)
            super(persistor)
            @source = source
          end

          def setup(run) = __getobj__.setup(run, source: @source)
        end
      end
    end
  end
end
