# frozen_string_literal: true

module Space
  module Server
    module Runs
      module StreamKey
        TTL_SECONDS = 1800  # 30 minutes

        def self.for(run_id)
          "run:#{run_id}"
        end
      end
    end
  end
end
