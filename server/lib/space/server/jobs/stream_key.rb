# frozen_string_literal: true

module Space
  module Server
    module Jobs
      # Single owner of the frozen raw-stream key (mirror of Runs::StreamKey):
      # the executor writes job:<id>:raw and the consumer drains it.
      module StreamKey
        TTL_SECONDS = 1800  # 30 minutes

        def self.for(job_id)
          "job:#{job_id}:raw"
        end
      end
    end
  end
end
